# getsshpass

A dictionary-based SSH password auditing tool for authorized security testing.

Originally created in 2016 by [Radovan Brezula](https://brezular.com/2016/01/11/bash-script-for-dictionary-attack-against-ssh-server/) as a proof-of-concept SSH brute-forcer. I (Blai Peidro) joined the project that same year and have since completely rewritten the codebase with security hardening, improved resume support, parallel job control, signal-safe process cleanup, and modern bash practices.

In benchmarks against a local host, getsshpass found a password at row 5,000 of `rockyou.txt` (14.3M lines) in approximately 3 min 29 sec - outperforming THC Hydra (4 min 45 sec with its maximum 64 parallel sessions) using sshpass with only 5 parallel jobs and a 0.04s delay between attempts on the same target.

**Table of contents**

- [Features](#features)
- [File structure](#file-structure)
- [Requirements](#requirements)
- [Usage](#usage)
  - [Steps](#steps)
  - [Options](#options)
  - [Examples](#examples)
  - [Example output](#example-output)
- [Wordlists](#wordlists)
  - [Wordlist format](#wordlist-format)
  - [Downloading wordlists](#downloading-wordlists)
  - [Adding wordlists](#adding-wordlists)
- [How it works](#how-it-works)
  - [SSH_ASKPASS mode (default)](#ssh_askpass-mode-default)
  - [sshpass mode](#sshpass-mode)
  - [Performance tuning](#performance-tuning)
- [Interrupting and resuming](#interrupting-and-resuming)
  - [Signal handling](#signal-handling)
  - [State files](#state-files)
  - [Clearing state](#clearing-state)
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
- Colored terminal output
- Configurable connection timeout and delay between attempts
- Supports both IP addresses and hostnames as targets
- Signal handling with clean process cleanup
- Timestamped log output with standard log levels (`[OK   ]`, `[INFO ]`, `[WARN ]`, `[ERROR]`)
- Built-in wordlist fetching and listing from popular sources (rockyou, SecLists)

## File structure

Project files and runtime state layout:

```
getsshpass/
├── src/
│   ├── getsshpass.sh          # Main script
│   ├── wordlists.txt          # Wordlist fetch catalog (NAME|FILENAME|DESCRIPTION|URL)
│   └── .getsshpass/           # Runtime state directory (auto-created, gitignored)
│       └── <host>/            # Per-host subdirectory
│           ├── filter_tmp/          # Transient dir during user filtering (auto-deleted)
│           │   └── <user>           # Marker file per user with password authentication enabled
│           ├── filtered_users.txt   # Users with password authentication enabled
│           ├── result.txt           # Found credentials
│           └── resume.txt           # Last attempted username:password
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # Contribution guidelines
├── LICENSE                # GPLv3+ license
└── README.md              # This file
```

## Requirements

- Bash 4.4+
- ssh (OpenSSH 8.4+ client required for default SSH_ASKPASS mode; any version works with `-s/--sshpass`)
- curl (optional, for `--fetch` wordlist feature)
- sshpass (optional, for `-s/--sshpass` mode)

The script checks for `ssh` at startup and exits with a clear error if it is missing. When using the default SSH_ASKPASS mode, it also checks that the OpenSSH client is version 8.4 or newer (required for `SSH_ASKPASS_REQUIRE=force`) and exits with an error directing the user to `-s/--sshpass` if not.

If `-s/--sshpass` is used, the script checks for `sshpass` at startup and exits if it is missing.

## Usage

### Steps

1. Clone the repository and make the script executable:

```bash
git clone https://github.com/blaipr/getsshpass.git
cd getsshpass/src
chmod +x getsshpass.sh
```

2. Download a users list:

```bash
./getsshpass.sh --fetch top-usernames
```

3. Download a passwords list:

```bash
./getsshpass.sh --fetch rockyou
```

4. Launch the attack:

```bash
./getsshpass.sh -a <host> -u top-usernames-shortlist.txt -d rockyou.txt
```

### Options

`getsshpass.sh` has both short and long options forms:

```
Usage: getsshpass.sh [OPTIONS]

OPTIONS:
   -a, --attack HOST      IP address or hostname of target SSH host
   -p, --port PORT        TCP port 1-65535 of target SSH host [default: 22]
   -u, --users FILE       Path to file with usernames (repeatable)
   -d, --dictionary FILE  Path to file with passwords (repeatable)
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

Multiple wordlist files (concatenated in order):

```bash
./getsshpass.sh -a 192.168.1.1 -u admins.txt -u users.txt -d common.txt -d rockyou.txt
```

Password spray (try each password across all users before moving to the next):

```bash
./getsshpass.sh -a 192.168.1.1 -d rockyou.txt -u users.txt
```

### Example output

```
$ ./getsshpass.sh -a 192.168.1.1 -p 22 -u users.txt -d passwords.txt -j 5
2026-05-10 14:23:44 [INFO ] Target:              192.168.1.1:22
2026-05-10 14:23:44 [INFO ] SSH method:          SSH_ASKPASS
2026-05-10 14:23:44 [INFO ] SSH parallel jobs:   max 5
2026-05-10 14:23:44 [INFO ] SSH delay:           0.04s
2026-05-10 14:23:44 [INFO ] SSH timeout:         8s
2026-05-10 14:23:44 [INFO ] SSH retries:         50
2026-05-10 14:23:44 [INFO ] Users file:          users.txt
2026-05-10 14:23:44 [INFO ] Passwords file:      passwords.txt
2026-05-10 14:23:44 [INFO ] Attack order:        users first
2026-05-10 14:23:44 [INFO ] Checking SSH connection to '192.168.1.1:22'...
2026-05-10 14:23:46 [OK   ] Connection successful
2026-05-10 14:23:46 [INFO ] Filtering users by password authentication...
2026-05-10 14:23:51 [INFO ] 3/4 users allow password authentication
2026-05-10 14:23:51 [INFO ] Users:                       3 / 4
2026-05-10 14:23:51 [INFO ] Passwords:                   4
2026-05-10 14:23:51 [INFO ] Combinations:                12
2026-05-10 14:23:51 [INFO ] Starting attack...
2026-05-10 14:23:52 [INFO ] Passwords tried:             9
2026-05-10 14:23:52 [INFO ] Passwords remaining:         3
2026-05-10 14:24:01 [OK   ] Found username: 'deploy' and password: '123456'
2026-05-10 14:24:01 [INFO ] Elapsed time: 16s
```

The current attempt overwrites in place (`\r`), so only the last tried combination is visible as a scrolling line below the counter rows. The `Passwords tried` and `Passwords remaining` lines are pinned immediately after `Starting attack...` and update live with every attempt. A progress bar showing percentage and count is pinned at the very bottom row of the terminal throughout the attack. When output is piped or redirected (non-terminal), colors and the pinned display are disabled and each attempt is printed as a plain `[count/total]` line instead.

If no password is found after exhausting all combinations:

```
2026-05-10 14:27:21 [WARN ] Password not found. Try a different dictionary.
2026-05-10 14:27:21 [INFO ] Elapsed time: 3m 29s
```

## Wordlists

A wordlist (also called a dictionary) is a plain text file containing one candidate entry per line - usernames or passwords. The tool systematically tries every username/password combination from these lists against the target.

### Wordlist format

Empty lines are skipped automatically. Windows line endings (`\r\n`) are handled transparently. Files should end with a trailing newline, though the last line is processed either way.

### Downloading wordlists

I added built-in wordlist downloading so you don't have to search for them. Available wordlists are defined in `src/wordlists.txt` (see [File structure](#file-structure)). Use `-l`/`--list` to see what's available and `-f`/`--fetch` to download:

```bash
./getsshpass.sh --list                    # show available wordlists
./getsshpass.sh --fetch top-usernames     # top-usernames-shortlist.txt - 17 top usernames, 1 KB
./getsshpass.sh --fetch rockyou           # rockyou.txt - 14.3M passwords, 134 MB
./getsshpass.sh --fetch 10k               # 10k-most-common.txt - 10,000 passwords, 71 KB
./getsshpass.sh --fetch 100k              # 100k-passwords.txt - 100,000 passwords, 816 KB
./getsshpass.sh -f 10k -f 100k            # fetch multiple at once
```

Wordlists are downloaded to the current directory. If the file already exists, the download is skipped. Requires `curl`.

### Adding wordlists

To add your own wordlists, edit `src/wordlists.txt` and add one line per wordlist using this format:

```
NAME|FILENAME|DESCRIPTION|URL
```

- **NAME** - Short identifier used with `-f/--fetch` (e.g. `rockyou`)
- **FILENAME** - Local filename to save as (e.g. `rockyou.txt`)
- **DESCRIPTION** - Brief description shown by `--list` (e.g. `14.3M passwords, 134 MB`)
- **URL** - Direct download URL for the wordlist

## How it works

1. **Connection check** - Connects to the target over SSH using `admin:admin` as a quick-win test: if the most common default credential succeeds immediately, there is no need to run the full dictionary attack and the script reports the finding and ends. All SSH commands use `-o StrictHostKeyChecking=no` (accept any host key) and `-o PubkeyAuthentication=no` (force password authentication). In default mode (`SSH_ASKPASS`), `-o NumberOfPasswordPrompts=1` is also set to fail fast on bad passwords; SSH exits with 255 for both authentication failure and connection errors, so the script captures stderr to tell them apart: `Permission denied` in the output means the server is reachable but rejected the password - attack proceeds; anything else with exit 255 is a real connection failure and the script exits. In `--sshpass` mode, `NumberOfPasswordPrompts=1` is omitted because sshpass relies on detecting the second password prompt to return exit code 5 for authentication failure; sshpass returns distinct exit codes (5 = auth failure, 3/255 = connection error) so no stderr capture is needed.

2. **User filtering** - Probes all usernames in parallel from the wordlist using `ssh -o BatchMode=yes`. When BatchMode is enabled, SSH will not prompt for a password - if the server responds mentioning "password" or "keyboard-interactive" in its output, that user has password-based authentication enabled. Users that only accept key-based authentication are skipped. When `-j/--jobs` is set, filtering respects the same concurrency cap; otherwise all probes run simultaneously - with a large username list this can open many connections to the target at once. If no users in the list have password authentication enabled, the script exits immediately with `[WARN ] No users with password authentication found` and does not run the attack. Each parallel probe writes a marker file named after the user into a temporary directory `filter_tmp/` inside the host's state directory. Once all probes complete, the script rebuilds `filtered_users.txt` by reading back the original userlist in order and including only users that have a marker file in `filter_tmp/`, preserving the original input order. `filter_tmp/` is deleted immediately after. On subsequent runs against the same host, if a cached `filtered_users.txt` already exists, the script asks whether to reuse it (`Reuse cached list? [Y/n]`) - defaulting to Yes - so the filtering step can be skipped entirely.

3. **Resume detection** - If a previous run was interrupted, the script detects `resume.txt` and restores progress from the last attempted credential pair (see [State files](#state-files) below).

4. **Dictionary attack** - The relative position of the first `-u` and first `-d` argument determines the outer loop: `-u` before `-d` iterates users as the outer loop (all passwords tried per user before moving to the next user); `-d` before `-u` iterates passwords as the outer loop, which is the classic password spray pattern (one password tried across all users before moving to the next password). The chosen order is shown in the pre-flight summary as `Attack order`. If multiple `-u/--users` or `-d/--dictionary` files are given, each set is concatenated into a single temporary file in the order specified before the attack starts. Tries every username/password combination using parallel background jobs. By default, parallelism is unlimited; use `-j/--jobs` to cap the number of concurrent SSH sessions. When `-j` is set, the script polls every 50ms for a free job slot before launching the next attempt. A delay (`-w/--wait`) is applied between attempts to avoid overwhelming the target or triggering rate limiting. Retries on transient SSH errors use a fixed 50ms sleep independent of `-w/--wait`, up to `-r/--retries` (default: 50) retries per attempt. If the retry limit is hit, the script emits a `[WARN ]` message and skips that credential pair - the attack continues with the next one. If one job finds the password, all other jobs that are mid-retry detect the result file and stop immediately without exhausting their remaining retries. Finished child PIDs are pruned from the tracking array when it exceeds `PID_PRUNE_THRESHOLD` (200) entries, so the signal handler's cleanup loop only iterates over live processes, avoiding unnecessary `kill` and `wait` calls.

5. **Result reporting** - On success, emits a terminal bell (`\a`) to alert the user, displays the found credentials and the time elapsed since the attack started (e.g. `16s`, `3m 29s`, `1d 2h 15m 3s`), then exits with code 0. On failure (all combinations exhausted), exits with code 1 after displaying the message: `Password not found. Try a different dictionary.` and the elapsed time. Note: the timer resets when the attack loop begins, so pre-flight checks and user filtering are not included.

### SSH_ASKPASS mode (default)

SSH cannot accept a password on stdin when a terminal is present - it reads passwords interactively from `/dev/tty`. To automate password delivery without `sshpass`, the script uses OpenSSH's `SSH_ASKPASS` mechanism.

At startup, before the first SSH attempt, one small temporary executable file is created via `mktemp` with this code in it:

```sh
#!/bin/sh
printf "%s\n" "${SSH_PASSWORD}"
```

This file prints the `SSH_PASSWORD` environment variable and exits, ignoring any arguments SSH passes to it (SSH calls the helper with its own prompt string as an argument, e.g. `"admin@192.168.1.1's password:"` - an `echo` would print that prompt string instead of the password, so this file is needed to ignore it and print only `$SSH_PASSWORD`).

For every SSH attempt the script sets three environment variables alongside the `ssh` command:

| Variable | Value | Purpose |
|----------|-------|---------|
| `SSH_ASKPASS` | path to the temp script | tells SSH which program to call for the password |
| `SSH_ASKPASS_REQUIRE` | `force` | forces SSH to call the helper even when a terminal is present (OpenSSH 8.4+; without this, SSH ignores `SSH_ASKPASS` if stdin is a tty) |
| `SSH_PASSWORD` | current password candidate | what the helper will print to SSH |

The temp file is created once at startup and reused for every attempt throughout the run - only `SSH_PASSWORD` changes per attempt, not the file itself. It is deleted on any exit via `cleanup()`.

`SSH_ASKPASS_REQUIRE=force` was introduced in OpenSSH 8.4. On older versions the option does not exist, so SSH ignores the helper and falls back to prompting on the terminal - making unattended password injection impossible. Use `-s/--sshpass` if an older OpenSSH client must be used.

**Return values:**

| Code | stderr contains `Permission denied` | Meaning |
|------|--------------------------------------|---------|
| 0    | -                                    | Password OK |
| 255  | yes                                  | Authentication failure (bad password) |
| 255  | no                                   | Connection failure (refused, unreachable, DNS, etc.) |

SSH exits with 255 for both outcomes. The script captures stderr to distinguish them. Connection errors are retried up to `-r/--retries` (default: 50) times; authentication failures are not.

### sshpass mode

[`sshpass`](https://sourceforge.net/projects/sshpass/) passes the password to SSH by running as the parent process of `ssh` and responding to its password prompt automatically. The binary must be installed separately; the script checks for it at startup and exits with an error if it is missing when `-s/--sshpass` flag is used.

In `--sshpass` mode the `-o NumberOfPasswordPrompts=1` option is intentionally omitted. Without it, SSH issues a second password prompt on authentication failure  -  sshpass detects the repeated prompt and returns exit code 5. With the option set, SSH exits with 255 immediately on the first failure before issuing the second prompt; sshpass never detects the auth failure and returns 255 instead of 5, causing the script to treat every failed password as a connection error and exhaust retries needlessly.

**Return values:**

| Code | Meaning |
|------|---------|
| 0    | Password OK |
| 5    | Authentication failure (bad password) |
| 3    | Runtime error (connection failure) |
| 255  | Connection failure (refused, unreachable, DNS, etc.) |

sshpass returns distinct exit codes, so no stderr capture is needed. Connection errors are retried up to `-r/--retries` (default: 50) times; authentication failures are not.

### Performance tuning

The `-j/--jobs`, `-w/--wait`, and `-t/--timeout` flags control how aggressively the script connects to the target:

- **`-j/--jobs` (parallel jobs)** - Limits concurrent SSH sessions. Use `0` (the default) for unlimited parallelism, or set a cap to reduce load on the target. The script automatically retries on connection errors (exit 255 in SSH_ASKPASS mode; exit 3 or 255 in sshpass mode), but excessive parallelism still wastes time on retries. Default: 0 (unlimited).

- **`-w/--wait` (delay)** - Time in seconds between launching each attempt. Lower values are faster but more likely to overwhelm the target. Use `0.5` or higher for remote hosts or when stealth matters. Default: 0.04.

- **`-t/--timeout` (timeout)** - How long to wait for an SSH connection before giving up. Increase this for high-latency targets. Default: 8 seconds.

- **`-s/--sshpass` (sshpass mode)** - Use `sshpass` to pass passwords instead of the native `SSH_ASKPASS` mechanism. sshpass returns distinct exit codes for auth failure vs connection errors, avoiding the stderr capture overhead used in default mode. Requires `sshpass` installed.

Three internal constants are hardcoded in the script and are not exposed as flags:

- **`RETRY_SLEEP` (0.05s)** - Fixed delay between retries when a connection error occurs. Intentionally short and independent of `--wait` so that transient errors are retried quickly regardless of the configured attack delay.

- **`POLL_SLEEP` (0.05s)** - Fixed delay between checks when waiting for a free job slot (`-j/--jobs` limit). Shorter values reduce slot-acquisition latency; longer values reduce CPU spinning.

- **`PID_PRUNE_THRESHOLD` (200)** - The child PID tracking array is pruned of finished processes when it exceeds this many entries. Lower values prune more often (more `kill -0` probes, slightly more CPU); higher values let the array grow larger between prunes.

To change these, edit the constants at the top of `src/getsshpass.sh`.

Recommendations:

- **Local LAN** target: defaults work well (`--wait 0.04`, unlimited jobs).
- **Remote host** or when you want to avoid triggering alarms: `--wait 0.5 --jobs 3` or slower.
- **Maximum speed**: add `--sshpass` if `sshpass` is available.

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

Exit codes follow the convention `128 + signal_number`:

| Signal | Number | Exit code |
|--------|--------|-----------|
| SIGHUP  | 1  | 129 |
| SIGINT  | 2  | 130 |
| SIGQUIT | 3  | 131 |
| SIGTERM | 15 | 143 |
| SIGTSTP | 20 | 148 |

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

**On next run**, the script detects `resume.txt` and parses it as a tab-separated `username\tpassword` pair (tab is used instead of colon so usernames and passwords containing colons are handled correctly). It looks up each value in the wordlist files using `grep -Fxn` (literal, full-line match) to find the line number, then uses `tail -n +<line>` (print from line N to end of file, skipping everything before it) to write trimmed copies as temporary `.new` files created next to the original wordlist files (e.g. `rockyou.txt` → `rockyou.txt.new`). The attack reads from these trimmed files, starting at the last attempted pair - retrying it first - then continuing with the remaining entries. If the saved username is not found in the user list, a warning is emitted and the entire attack restarts from the beginning of both lists. If the saved password is not found in the password list (but the username was found), a warning is emitted and only the password list restarts from the beginning for that username. The `.new` files are cleaned up automatically on exit (any exit code).

**On success**, `result.txt` is written with the found credentials. If the script is run again to the same host while `result.txt` exists in its folder, it shows the saved password and asks whether to run again:

```
Warning: Previous result found for '192.168.1.1': user 'admin', password 'admin'
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
