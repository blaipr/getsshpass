# getsshpass

A dictionary-based SSH password auditing tool for authorized security testing.

Originally created in 2016 by [Radovan Brezula](https://brezular.com/2016/01/11/bash-script-for-dictionary-attack-against-ssh-server/) as a proof-of-concept SSH brute-forcer. I (Blai Peidro) joined the project that same year and have since completely rewritten the codebase with security hardening, improved resume support, parallel job control, signal-safe process cleanup, and modern bash practices.

In benchmarks against a local host with SSH active, getsshpass found a password at row 5,000 of `rockyou.txt` (14.3M lines) in approximately 3 min 29 sec - outperforming the well-known pentesting tool THC Hydra (4 min 45 sec with its maximum 64 parallel sessions) using only 5 parallel jobs and a 0.04s delay between attempts on the same target.

**Table of contents**

- [Features](#features)
- [File structure](#file-structure)
- [Requirements](#requirements)
- [Usage](#usage)
- [Wordlists](#wordlists)
- [How it works](#how-it-works)
- [Interrupting and resuming](#interrupting-and-resuming)
- [Code style](#code-style)
- [Changelog](#changelog)
- [Authors](#authors)
- [License](#license)
- [Disclaimer](#disclaimer)

## Features

- Dictionary attack against SSH services using username and password lists
- Automatic filtering to skip users without password authentication enabled
- Parallel SSH attempts with unlimited concurrency by default (configurable with `-j`)
- Resume capability - interrupted attacks can be continued from where they left off
- Live attempt display with apt-style progress bar pinned at the bottom of the terminal
- Colored terminal output with auto-detection and thousand-separated counters
- Configurable connection timeout and delay between attempts
- Supports both IP addresses and hostnames as targets
- Signal handling with clean process cleanup
- Timestamped log output with standard log levels (`[OK   ]`, `[INFO ]`, `[WARN ]`, `[ERROR]`)
- Built-in wordlist fetching and listing from popular sources (rockyou, SecLists)

## File structure

Project files and runtime state layout:

```
getsshpass/
├── getsshpass.sh          # Main script
├── wordlists.txt          # Wordlist fetch catalog (NAME|FILENAME|DESCRIPTION|URL)
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # Contribution guidelines
├── LICENSE                # GPLv3+ license
├── README.md              # This file
├── .gitignore             # Ignores .getsshpass/, *.new, and downloaded wordlists
└── .getsshpass/           # Runtime state directory (auto-created, gitignored)
    └── <host>/            # Per-host subdirectory
        ├── result.txt           # Found credentials
        ├── resume.txt           # Last attempted username:password
        ├── filtered_users.txt   # Users with password auth enabled
        └── filter_tmp/          # Transient dir during user filtering (auto-deleted)
            └── <user>           # Marker file per user with password auth enabled
```

## Requirements

- Bash 4.2+
- [sshpass](https://sourceforge.net/projects/sshpass/)
- ssh (OpenSSH client)
- curl (optional, for `--fetch` wordlist feature)

The script checks for `sshpass` at startup and exits with a clear error if it is missing.

### Install dependencies

**Debian / Ubuntu:**

```bash
sudo apt install sshpass openssh-client
```

**RHEL / CentOS / Fedora:**

```bash
sudo dnf install sshpass openssh-clients
```

**Arch Linux:**

```bash
sudo pacman -S sshpass openssh
```

**macOS (Homebrew):**

```bash
brew install hudochenkov/sshpass/sshpass
```

## Usage

### Steps

1. Clone this repository or fetch the script file
2. Download a users list
3. Download a passwords list
4. Launch the attack against a host

### Options

`getsshpass.sh` has both short and long options forms:

```
Usage: getsshpass.sh [OPTIONS]

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
```

### Examples

Basic usage:

```bash
./getsshpass.sh -a 192.168.1.1 -p 22 -u users.txt -d passwords.txt
```

With hostname, slower delay, and limited parallelism:

```bash
./getsshpass.sh -a server.local -p 22 -u users.txt -d passwords.txt -w 0.5 -j 3
```

Maximum speed (no delay between attempts):

```bash
./getsshpass.sh -a 10.0.0.5 -u users.txt -d passwords.txt --wait 0.0
```

### Example output

```
$ ./getsshpass.sh -a 192.168.1.1 -p 22 -u users.txt -d passwords.txt -j 5
2026-05-10 14:23:45 [INFO ] Checking SSH connection to '192.168.1.1:22'...
2026-05-10 14:23:47 [OK   ] Connection successful
2026-05-10 14:23:47 [INFO ] Filtering users with password authentication enabled...
2026-05-10 14:23:52 [INFO ] Found 3/4 users with password authentication enabled
2026-05-10 14:23:52 [INFO ] Starting attack against 192.168.1.1:22 (max 5 parallel jobs, 0.04s delay)
2026-05-10 14:23:52 [INFO ] Users to try: 3
2026-05-10 14:23:52 [INFO ] Passwords to try: 4
2026-05-10 14:23:52 [INFO ] Total combinations: 12
2026-05-10 14:24:01 [OK   ] Found username: 'deploy' and password: '123456'
2026-05-10 14:24:01 [INFO ] Elapsed time: 16s
```

The attempt line overwrites in place (`\r`), so only the last attempted combination is visible. A progress bar is displayed at the bottom of the terminal during the attack. When output is piped or redirected (non-terminal), colors and the progress bar are disabled and each attempt is printed as a plain `[count/total]` line instead.

If no password is found after exhausting all combinations:

```
2026-05-10 14:27:20 [INFO ] Trying user: 'deploy' password: 'changeme'
2026-05-10 14:27:21 [WARN ] Password not found. Try a different dictionary.
2026-05-10 14:27:21 [INFO ] Elapsed time: 3m 29s
```

## Wordlists

A wordlist (also called a dictionary) is a plain text file containing one candidate entry per line - usernames or passwords. The tool systematically tries every username/password combination from these lists against the target.

### Wordlist format

Empty lines are skipped automatically. Windows line endings (`\r\n`) are handled transparently. Files should end with a trailing newline, though the last line is processed either way.

### Downloading wordlists

I added built-in wordlist downloading so you don't have to search for them. Available wordlists are defined in `wordlists.txt` (see [File structure](#file-structure)). Use `-l`/`--list` to see what's available and `-f`/`--fetch` to download:

```bash
./getsshpass.sh --list               # show available wordlists
./getsshpass.sh --fetch rockyou      # rockyou.txt - 14.3M passwords, 134 MB
./getsshpass.sh --fetch 10k          # 10k-most-common.txt - 10,000 passwords, 71 KB
./getsshpass.sh --fetch 100k         # 100k-passwords.txt - 100,000 passwords, 816 KB
./getsshpass.sh -f 10k -f 100k       # fetch multiple at once
```

Wordlists are downloaded to the current directory. If the file already exists, the download is skipped. Requires `curl`.

### Adding wordlists

To add your own wordlists, edit `wordlists.txt` and add one line per wordlist using this format:

```
NAME|FILENAME|DESCRIPTION|URL
```

- **NAME** - Short identifier used with `-f/--fetch` (e.g. `rockyou`)
- **FILENAME** - Local filename to save as (e.g. `rockyou.txt`)
- **DESCRIPTION** - Brief description shown by `--list` (e.g. `14.3M passwords, 134 MB`)
- **URL** - Direct download URL for the wordlist

## How it works

1. **Connection check** - Connects to the target over SSH using `admin:admin`. If it succeeds, the script reports the finding and ends. If SSH returns exit code 255 (connection refused, host unreachable, DNS failure, etc.), the script exits with an error. Any other response (e.g. bad password) confirms the server is reachable and the attack proceeds. All SSH commands throughout the script use `-o StrictHostKeyChecking=no` (accept any host key) and `-o PubkeyAuthentication=no` (force password authentication).

2. **User filtering** - Probes all usernames in parallel from the wordlist using `ssh -o BatchMode=yes`. When BatchMode is enabled, SSH will not prompt for a password - if the server responds mentioning "password" or "keyboard-interactive" in its output, that user has password-based authentication enabled. Users that only accept key-based authentication are skipped. Each parallel probe writes a marker file named after the user into a temporary directory `filter_tmp/` inside the host's state directory. Once all probes complete, the script rebuilds `filtered_users.txt` by reading back the original userlist in order and including only users that have a marker file in `filter_tmp/`, preserving the original input order. `filter_tmp/` is deleted immediately after. On subsequent runs against the same host, if a cached `filtered_users.txt` already exists, the script asks whether to reuse it (`Reuse cached list? [Y/n]`) - defaulting to Yes - so the filtering step can be skipped entirely.

3. **Resume detection** - If a previous run was interrupted, the script detects `resume.txt` and restores progress from the last attempted credential pair (see [State files](#state-files) below).

4. **Dictionary attack** - Tries every username/password combination using parallel background jobs. By default, parallelism is unlimited; use `-j/--jobs` to cap the number of concurrent SSH sessions. When `-j` is set, the script polls every 50ms for a free job slot before launching the next attempt. A delay (`-w/--wait`) is applied between attempts to avoid overwhelming the target or triggering rate limiting. The same delay is used between retries on transient SSH errors (codes 3 and 255, up to `-r/--retries` (default: 50) retries per attempt). If one job finds the password, all other jobs that are mid-retry detect the result file and stop immediately without exhausting their remaining retries. Finished child PIDs are pruned from the tracking array every 100 attempts - so the signal handler's cleanup loop only iterates over live processes, avoiding unnecessary `kill` and `wait` calls.

5. **Result reporting** - On success, displays the found credentials and total elapsed time (e.g. `16s`, `3m 29s`, `1d 2h 15m 3s`), then exits with code 0. On failure (all combinations exhausted), exits with code 1 after displaying the message: `Password not found. Try a different dictionary.` and the total elapsed time.

### sshpass return values

| Code | Meaning |
|------|---------|
| 0    | Password OK |
| 3    | General runtime error |
| 5    | Bad password |
| 255  | SSH connection failure (refused, unreachable, DNS, etc.) |

These are the codes relevant to getsshpass. The script retries on codes 3 and 255 (transient errors, up to `-r/--retries` (default: 50) times), treats 0 as success, and 5 as a failed attempt.

### Performance tuning

The `-j/--jobs`, `-w/--wait`, and `-t/--timeout` flags control how aggressively the script connects to the target:

- **`-j/--jobs` (parallel jobs)** - Limits concurrent SSH sessions. Use `0` (the default) for unlimited parallelism, or set a cap to reduce load on the target. The script automatically retries on connection refused (exit code 255), but excessive parallelism still wastes time on retries. Default: 0 (unlimited).

- **`-w/--wait` (delay)** - Time in seconds between launching each attempt. Lower values are faster but more likely to overwhelm the target. Use `0.5` or higher for remote hosts or when stealth matters. Default: 0.04.

- **`-t/--timeout` (timeout)** - How long to wait for an SSH connection before giving up. Increase this for high-latency targets. Default: 8 seconds.

Recommendations:

- **Local LAN** target: defaults work well (`--wait 0.04`, unlimited jobs).
- **Remote host** or when you want to avoid triggering alarms: `--wait 0.5 --jobs 3` or slower.

## Interrupting and resuming

### Signal handling

The script handles the following signals:

| Signal | Trigger | Behavior |
|--------|---------|----------|
| SIGINT  | Ctrl+C  | Prints "[WARN ] Interrupted. Run the script again to resume.", cleans up child processes, exits with code 130 |
| SIGTSTP | Ctrl+Z  | Prints "[WARN ] Stopped. Run the script again to resume.", cleans up child processes, exits with code 148 |
| SIGHUP  | `kill -HUP` or terminal close | Cleans up child processes, exits with code 129 |
| SIGTERM | `kill` | Cleans up child processes, exits with code 143 |
| SIGQUIT | `kill -QUIT` | Cleans up child processes, exits with code 131 |
| SIGWINCH | Terminal resize | Redraws progress bar to fit new terminal dimensions |

Child processes are tracked by PID and terminated individually during cleanup, so only processes spawned by the script are affected - no other system processes are touched.

### State files

After launching an attack, state files are stored per-host in `.getsshpass/<host>/` inside the script directory, so results from different targets don't overwrite each other:

| File | Purpose |
|------|---------|
| `.getsshpass/` | Root state directory, created automatically inside the script directory and gitignored. Contains one subdirectory per target host, so state from different targets never collides. Can be deleted manually to wipe all state for all hosts. |
| `.getsshpass/<host>/` | Per-host subdirectory, named after the target hostname or IP. Created automatically on the first run against that host and reused on subsequent runs. |
| `resume.txt` | Last attempted `username\tpassword` pair (tab-separated), written before each attempt |
| `result.txt` | Found credentials, written on success |
| `filtered_users.txt` | Usernames with password authentication enabled, generated during the filtering step and reused on subsequent runs if present |
| `filter_tmp/` | Transient directory used during user filtering. Each parallel probe creates a file named after the username (e.g. `filter_tmp/root`) containing the username, only if that user has password authentication enabled. Users that only accept key-based auth get no file. Once all probes finish, the script checks for file existence to rebuild `filtered_users.txt` in original order, then deletes `filter_tmp/`. If interrupted mid-filter the directory is left behind, but the next run removes it at the start of filtering. |

**On interruption** (Ctrl+C, Ctrl+Z, or kill signal), the script cleans up child processes and exits. The `resume.txt` file remains with the last attempted credentials.

**On next run**, the script detects `resume.txt` and parses it as a tab-separated `username\tpassword` pair (tab is used instead of colon so usernames and passwords containing colons are handled correctly). It looks up each value in the wordlist files using `grep -Fxn` (literal, full-line match) to find the line number, then uses `tail -n +<line>` to write trimmed copies as temporary `.new` files created next to the original wordlist files (e.g. `rockyou.txt` → `rockyou.txt.new`). The attack reads from these trimmed files, resuming from the last attempted entry and potentially retrying only that one pair. If the saved password is not found in the password list, a warning is emitted and the password list starts from the beginning. The `.new` files are cleaned up automatically on exit (any exit code).

**On success**, `result.txt` is written with the found credentials. If the script is run again to the same host while `result.txt` exists in its folder, it shows the saved password and asks whether to run again:

```
2026-05-10 14:30:12 [WARN ] Previous result found for '192.168.1.1': user 'admin', password 'admin'
Run again anyway? [y/N]
```

Answering `y` clears state files for that host and starts a fresh attack. Answering `N` (or Enter) exits.

### Clearing state

Use the `-c/--clear` flag to delete state files, or remove the `.getsshpass/` directory manually. When combined with the `-a/--attack` flag, only that host's state is cleared. Without `-a`, state for all hosts is removed:

```bash
./getsshpass.sh --clear --attack 192.168.1.1   # clear state for one host
./getsshpass.sh --clear                        # clear state for all hosts
rm -rf .getsshpass/                            # manual alternative
```

## Code style

This project follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html). See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

## Authors

- **Radovan Brezula** ([brezular](https://brezular.com)) - original author
- **Blai Peidro** - co-author

## License

GPLv3+ - GNU General Public License version 3 or later.
See [LICENSE](LICENSE) for details.

## Disclaimer

This tool is intended for **authorized security auditing and penetration testing only**. Unauthorized access to computer systems is illegal. Always obtain proper written authorization before testing any system you do not own.
