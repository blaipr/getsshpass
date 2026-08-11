# How it works

getsshpass runs an SSH dictionary attack in five stages, from a quick pre-flight check to a final verdict. This page walks through that pipeline, then digs into the two password-delivery mechanisms and the knobs that control how aggressively it connects.

**Contents**

- [The attack pipeline](#the-attack-pipeline)
  - [1. Connection check](#1-connection-check)
  - [2. User filtering](#2-user-filtering)
  - [3. Resume detection](#3-resume-detection)
  - [4. Dictionary attack](#4-dictionary-attack)
  - [5. Second pass and result reporting](#5-second-pass-and-result-reporting)
- [Modes](#modes)
  - [SSH_ASKPASS mode (default)](#ssh_askpass-mode-default)
  - [sshpass mode](#sshpass-mode)
- [Performance tuning](#performance-tuning)
  - [Command-line flags](#command-line-flags)
  - [Internal constants](#internal-constants)
  - [Recommendations](#recommendations)

---

## The attack pipeline

Every run moves through the same five stages. Stages 1-3 are pre-flight; the attack itself happens in stage 4, and stage 5 decides the outcome.

### 1. Connection check

Before the dictionary runs, the script tries `admin:admin` as a quick win. If that most-common default credential succeeds, there is no need for the full attack - the script reports the finding and ends.

All SSH commands use `-o StrictHostKeyChecking=no` (accept any host key) and `-o PubkeyAuthentication=no` (force password authentication).

In default (`SSH_ASKPASS`) mode, `-o NumberOfPasswordPrompts=1` is also set to fail fast on bad passwords. SSH exits with 255 for both authentication failure and connection errors, so the script captures stderr to tell them apart: `Permission denied` means the server is reachable but rejected the password (the attack proceeds), while anything else with exit 255 is a real connection failure (the script exits). In `--sshpass` mode this stderr capture is unnecessary, because sshpass returns distinct exit codes (5 = auth failure, 3/255 = connection error).

### 2. User filtering

The script probes every username in parallel with `ssh -o BatchMode=yes`. With BatchMode on, SSH never prompts for a password; if the server's response mentions "password" or "keyboard-interactive", that user has password authentication enabled. Users that only accept key-based auth are skipped.

Concurrency follows the same `-j/--jobs` cap as the attack when it is set; otherwise every probe runs at once, which can open many connections to a large username list simultaneously. If no user qualifies, the script exits immediately with `[WARN ] No users with password authentication found` and never starts the attack.

Each probe writes a marker file named after its user into a temporary `filter_tmp/` directory inside the host's state directory. Once all probes finish, the script rebuilds `filtered_users.txt` by re-reading the original list in order and keeping only users that have a marker, then deletes `filter_tmp/`.

On later runs against the same host, if a cached `filtered_users.txt` exists the script offers to reuse it (`Reuse cached list? [Y/n]`, defaulting to Yes), so filtering can be skipped entirely.

### 3. Resume detection

If a previous run was interrupted, the script detects `resume.txt` and restores progress from the last attempted credential pair (see [State files](state-and-resume.md#state-files)).

### 4. Dictionary attack

**Attack order.** The relative position of the first `-u` and first `-d` argument sets the outer loop: `-u` before `-d` iterates users first (every password per user), while `-d` before `-u` iterates passwords first - the classic password-spray pattern (one password across all users before the next). The chosen order appears in the pre-flight summary as `Attack order`. Multiple `-u` or `-d` files are concatenated into a single temporary file, in the order given, before the attack starts.

**Parallelism and pacing.** Each username/password combination runs as a background job. Parallelism is unlimited by default; `-j/--jobs` caps concurrent SSH sessions, and when set the script polls every 50 ms for a free slot before launching the next attempt. A `-w/--wait` delay between attempts avoids overwhelming the target or tripping rate limiting.

**Retries and penalties.** Transient connection errors are retried with exponential backoff (50 ms doubling to a 5 s cap), independent of `-w/--wait` and bounded by `-r/--retries` (default 50) and a 30 s cumulative per-pair budget (`RETRY_MAX_WAIT_MS`). When a pair exhausts its retries - usually an OpenSSH 9.8+ `PerSourcePenalties` block dropping the connection - it is recorded to `skipped.txt` instead of being silently discarded, and the run moves on; those pairs are retried in a serial second pass afterwards (stage 5).

**Stopping and cleanup.** As soon as one job finds the password, other jobs mid-retry notice the result file and stop without exhausting their retries. Finished child PIDs are pruned from the tracking array once it passes `PID_PRUNE_THRESHOLD` (200) entries, so the cleanup loop only iterates over live processes.

### 5. Second pass and result reporting

When the main loop finishes, any pairs in `skipped.txt` are retried serially by `retry_skipped`. Running one connection at a time lets a `PerSourcePenalties` block decay, so pairs skipped during the parallel flood still get a fair test before a verdict.

On success the script rings the terminal bell (`\a`), prints the found credentials and the elapsed time (e.g. `16s`, `3m 29s`, `1d 2h 15m 3s`), removes `skipped.txt`, and exits `0`.

On failure it exits `1`. If every combination was actually tested, it prints `Password not found. Try a different dictionary.`; if some pairs stayed untested even after the second pass, it reports an `INCONCLUSIVE` result instead, names the `skipped.txt` file, and suggests gentler settings (`-j 1 -w 5`) so you know the wordlist was not fully covered.

> The elapsed-time counter resets when the attack loop begins, so pre-flight checks and user filtering are not included in it.

---

## Modes

The script delivers each password candidate to `ssh` in one of two ways - the built-in `SSH_ASKPASS` mechanism (default) or the external `sshpass` binary - which differ mainly in how they report authentication versus connection failures.

## SSH_ASKPASS mode (default)

SSH cannot accept a password on stdin when a terminal is present - it reads passwords interactively from `/dev/tty`. To automate password delivery without `sshpass`, the script uses OpenSSH's `SSH_ASKPASS` mechanism.

At startup, before the first SSH attempt, one small temporary executable file is created via `mktemp` with this code in it:

```sh
#!/bin/sh
printf "%s\n" "${SSH_PASSWORD}"
```

This file prints the `SSH_PASSWORD` environment variable and exits, ignoring any arguments SSH passes to it. SSH calls the helper with its own prompt string as an argument (e.g. `"admin@192.168.1.1's password:"`); an `echo` would print that prompt instead of the password, so the helper is needed to ignore it and print only `$SSH_PASSWORD`.

For every SSH attempt the script sets three environment variables alongside the `ssh` command:

| Variable | Value | Purpose |
|----------|-------|---------|
| `SSH_ASKPASS` | path to the temp script | tells SSH which program to call for the password |
| `SSH_ASKPASS_REQUIRE` | `force` | forces SSH to call the helper even when a terminal is present (OpenSSH 8.4+; without this, SSH ignores `SSH_ASKPASS` if stdin is a tty) |
| `SSH_PASSWORD` | current password candidate | what the helper will print to SSH |

The temp file is created once at startup and reused for every attempt throughout the run - only `SSH_PASSWORD` changes per attempt, not the file itself. It is deleted on any exit via `cleanup()`.

`SSH_ASKPASS_REQUIRE=force` was introduced in OpenSSH 8.4. On older versions the option does not exist, so SSH ignores the helper and falls back to prompting on the terminal, making unattended password injection impossible. Use `-s/--sshpass` if an older OpenSSH client must be used.

**Return values:**

| Code | stderr contains `Permission denied` | Meaning |
|------|--------------------------------------|---------|
| 0    | -                                    | Password OK |
| 255  | yes                                  | Authentication failure (bad password) |
| 255  | no                                   | Connection failure (refused, unreachable, DNS, etc.) |

SSH exits with 255 for both outcomes, so the script captures stderr to distinguish them. Connection errors are retried up to `-r/--retries` (default 50) times; authentication failures are not.

## sshpass mode

[`sshpass`](https://sourceforge.net/projects/sshpass/) passes the password to SSH by running as the parent process of `ssh` and answering its password prompt automatically. The binary must be installed separately; the script checks for it at startup and exits with an error if it is missing when `-s/--sshpass` is used.

In `--sshpass` mode the `-o NumberOfPasswordPrompts=1` option is intentionally omitted. Without it, SSH issues a second password prompt on authentication failure, and sshpass detects that repeated prompt and returns exit code 5. With the option set, SSH exits with 255 on the first failure before the second prompt, so sshpass never detects the auth failure and returns 255 instead - which would make the script treat every failed password as a connection error and exhaust retries needlessly.

**Return values:**

| Code | Meaning |
|------|---------|
| 0    | Password OK |
| 5    | Authentication failure (bad password) |
| 3    | Runtime error (connection failure) |
| 255  | Connection failure (refused, unreachable, DNS, etc.) |

sshpass returns distinct exit codes, so no stderr capture is needed. Connection errors are retried up to `-r/--retries` (default 50) times; authentication failures are not.

---

## Performance tuning

The `-j/--jobs`, `-w/--wait`, and `-t/--timeout` flags control how aggressively the script connects to the target.

### Command-line flags

- **`-j/--jobs` (parallel jobs)** - Limits concurrent SSH sessions. Use `0` (the default) for unlimited parallelism, or set a cap to reduce load on the target. The script retries on connection errors automatically (exit 255 in SSH_ASKPASS mode; exit 3 or 255 in sshpass mode), but excessive parallelism still wastes time on retries. Default: 0 (unlimited).
- **`-w/--wait` (delay)** - Time in seconds between launching each attempt. Lower values are faster but more likely to overwhelm the target. Use `0.5` or higher for remote hosts or when stealth matters. Default: 0.04.
- **`-t/--timeout` (timeout)** - How long to wait for an SSH connection before giving up. Increase this for high-latency targets. Default: 8 seconds.
- **`-s/--sshpass` (sshpass mode)** - Use `sshpass` instead of the native `SSH_ASKPASS` mechanism. It returns distinct exit codes for auth failure vs connection errors, avoiding the stderr-capture overhead of default mode. Requires `sshpass` installed.

### Internal constants

These are hardcoded in the script and not exposed as flags:

- **`RETRY_BACKOFF_BASE_MS` (50ms)** / **`RETRY_BACKOFF_MAX_MS` (5000ms)** - Exponential backoff between retries when a connection error occurs: the wait starts at 50 ms and doubles each retry up to a 5 s cap. It is independent of `--wait` so transient errors are retried quickly, while a sustained block (e.g. `PerSourcePenalties`) is backed off from rather than hammered.
- **`RETRY_MAX_WAIT_MS` (30000ms)** - Cumulative inline retry budget per user/password pair. Once the total backoff for a pair exceeds this (or `--retries` is reached), the pair is deferred to the second-pass retry instead of stalling the whole run. 30 s is chosen to outlast the minimum OpenSSH penalty window.
- **`POLL_SLEEP` (0.05s)** - Fixed delay between checks when waiting for a free job slot (`-j/--jobs` limit). Shorter values reduce slot-acquisition latency; longer values reduce CPU spinning.
- **`PID_PRUNE_THRESHOLD` (200)** - The child PID tracking array is pruned of finished processes when it exceeds this many entries. Lower values prune more often (more `kill -0` probes, slightly more CPU); higher values let the array grow larger between prunes.

To change any of these, edit the constants at the top of `src/getsshpass.sh`.

### Recommendations

- **Local LAN** target: defaults work well (`--wait 0.04`, unlimited jobs).
- **Remote host**, or when you want to avoid triggering alarms: `--wait 0.5 --jobs 3` or slower.
- **Maximum speed**: add `--sshpass` if `sshpass` is available.

---

[← Back to the README](../README.md)
