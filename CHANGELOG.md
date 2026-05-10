# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.0] - 2026-05-11

Complete rewrite of the codebase with security hardening, modern bash practices, and new features.

### Added

- Hostname and FQDN support in addition to IP addresses
- Configurable parallel SSH attempts (`-j/--jobs`, default: unlimited)
- Configurable SSH connection timeout (`-t/--timeout`, default: 8s)
- SSH port defaults to 22 when `-p/--port` is not supplied
- Colored terminal output with automatic capability detection
- Timestamped log output (`[OK   ]`, `[INFO ]`, `[WARN ]`, `[ERROR]`)
- Apt-style progress bar with percentage and attempt counter
- SIGWINCH trap redraws progress bar on terminal resize
- Attempt line overwrites in place (`\r`) instead of one line per attempt
- Attack summary before starting (users, passwords, total combinations)
- Thousand-separated counters in all numeric output
- Long flags for all options (`--attack`, `--port`, `--jobs`, etc.)
- Per-host state directories (`.getsshpass/<host>/`) to isolate targets
- Filtered user list caching between runs with interactive reuse prompt
- `-c/--clear` flag to remove state files per host or globally
- Interactive prompt when previous results exist for a host
- Wordlist fetching via `-f/--fetch` with catalog (`wordlists.txt`)
- `-l/--list` flag to list available wordlists from the catalog
- Input validation for all flag values (port, jobs, timeout, delay, retries)
- File readability and non-empty checks for wordlists
- `-r/--retries N` flag for max retries on transient SSH errors (default: 50)
- Periodic pruning of finished child PIDs to prevent array growth
- `set -o pipefail` for safer error propagation
- CONTRIBUTING.md, LICENSE, README.md, and .gitignore

### Changed

- Code restructured into focused functions (`validate_host`, `try_ssh`, etc.)
- Flags renamed: `-d` to `-p`, `-p` to `-d`, `-n` to `-w`
- Argument parsing rewritten from `getopts` to `while/case` for long flags
- `try_ssh` accepts user/pass as arguments instead of relying on globals
- Signal cleanup tracks child PIDs instead of `pkill sshpass`
- Signal exit codes follow 128+signal convention (130, 148, 129, 143, 131)
- State files renamed to `result.txt`, `resume.txt`, `filtered_users.txt`
- All SSH commands use `-o PubkeyAuthentication=no`
- Elapsed time uses bash `SECONDS` instead of `bc`/`awk` pipeline
- Resume parsing uses parameter expansion instead of `head | cut`
- User filtering runs in parallel instead of sequentially
- User filtering detects `keyboard-interactive` auth (v0.9: only "password")
- User filtering uses `-t` timeout instead of hardcoded `ConnectTimeout=5`
- User filtering auth check uses `[[ =~ ]]` instead of `printf | grep`
- All variables quoted and braced per Google Shell Style Guide
- `echo -e` replaced with `printf` and heredocs throughout
- Script exits with code 1 when no password is found (was 0)

### Fixed

- `pkill sshpass` killed all system-wide sshpass processes
- No `wait` before evaluating results - reported "not found" prematurely
- IP regex had unescaped dot, no per-octet range check (accepted 999.x)
- Unquoted variables vulnerable to word splitting and globbing
- User filtering missing `-p "$port"` - always connected to port 22
- Resume treated usernames/passwords as regex - metacharacters mismatched
- Windows line endings (`\r\n`) in wordlists caused silent SSH failures
- Last line of wordlist skipped if file lacks trailing newline
- Background `try_ssh` inherited parent's stdin (wordlist fd)
- IP octet leading zeros caused octal misinterpretation
- Corrupted or empty resume file caused incorrect resume behavior

### Removed

- `bc` dependency - was only used for elapsed time

## [0.9] - 2018-05-01

User filtering, elapsed time display, and contributor credits.

### Added

- **User filtering**: probes each username via `ssh -o BatchMode=yes` to check if user has password authentication enabled
- **Elapsed time display**: shows total runtime on completion in days/hours/minutes/seconds format
- Full copyright/license header and script purpose description
- `exit` after displaying found credentials (v0.8 continued running)

### Changed

- Shebang from `#!/bin/bash` to `#!/usr/bin/env bash` for portability

### Removed

- Debug logging to `values.txt` that was added in v0.7

### Known issues

- `pkill sshpass` kills all system-wide sshpass processes, not just those spawned by the script
- `parallel_ssh` uses global variables instead of function arguments - race conditions when running in background
- IP regex has unescaped dot and no per-octet validation (accepts e.g. 999.999.999.999)
- No concurrency limit on background SSH jobs
- No `wait` before evaluating results - can report "not found" while jobs still running
- Several typos in user-facing messages
- Only accepts IP addresses, not hostnames
- User filtering (`ssh -o BatchMode=yes`) missing `-p` port flag - always connects to port 22 regardless of `-d` setting

## [0.8] - 2016-10-19

Elapsed time tracking and code cleanup.

### Added

- `START_TIME` variable and elapsed time tracking infrastructure (groundwork for v0.9's elapsed time display)
- Introduced `bc` and `awk` dependency for elapsed time calculation (removed in v1.0)

### Changed

- Signal handlers updated to `pkill sshpass` on exit with user-facing termination messages
- Reformatting and cleanup of comments and spacing

## [0.7] - 2016-10-17

Retry improvements, debug logging, and documentation of sshpass return codes.

### Added

- sshpass return value documentation in header comments (exit codes 0, 3, 5, 255)
- Comments explaining the retry loop logic
- Debug logging: writes `Password: $pass Value: $retval` to `values.txt`
- Cleanup of `.new` temp files in `evaluate_result`
- `initpasslist`/`inituserlist` variables for tracking original file paths

### Fixed

- `parallel_ssh` now also retries on exit code 3 (runtime error), not just 255
- Avoids missed passwords caused by a small `-n` delay

### Removed

- `sleep 2` from `evaluate_result` (was causing unnecessary delay)
- `exit 110` from `evaluate_result` (non-standard exit code)

## [0.6] - 2016-01-11

Original release by Radovan Brezula. Published at [brezular.com](https://brezular.com/2016/01/11/bash-script-for-dictionary-attack-against-ssh-server/).

- Dictionary attack against SSH services using `sshpass`
- Command-line interface with IP (`-a`), port (`-d`), delay (`-n`), password file (`-p`), username file (`-u`) options
- Parallel SSH attempts via background jobs with retry loop for connection refused (exit 255)
- Resume capability: saves last attempted username:password to `01xza01.txt`, restores progress on next run
- Found credentials stored to `x0x901f22result.txt`
- SSH connectivity pre-check with `admin:admin` default credential test
- Basic signal handling for SIGHUP, SIGTERM, SIGQUIT, SIGINT, SIGTSTP (exit only, no child cleanup)
- Default 0.04s delay between attempts
- `evaluate_result` used `sleep 2` before checking results and exited with code 110
