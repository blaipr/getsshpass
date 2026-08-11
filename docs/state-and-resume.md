# Interrupting and resuming

getsshpass is designed to survive interruptions and pick up where it left off. This page covers the signals it handles, the per-host state files it keeps, how a run resumes from those files, and how to clear that state.

**Contents**

- [Signal handling](#signal-handling)
- [State files](#state-files)
- [Run lifecycle](#run-lifecycle)
- [Clearing state](#clearing-state)

---

## Signal handling

The script handles the following signals:

| Signal | Trigger | Behavior | Exit code |
|--------|---------|----------|-----------|
| SIGHUP  | `kill -HUP` or terminal close | Cleans up child processes | 129 |
| SIGINT  | Ctrl+C  | Prints an "Interrupted" warning, cleans up child processes | 130 |
| SIGQUIT | `kill -QUIT` | Cleans up child processes | 131 |
| SIGTERM | `kill` | Cleans up child processes | 143 |
| SIGTSTP | Ctrl+Z  | Prints a "Stopped" warning, cleans up child processes | 148 |
| SIGWINCH | Terminal resize | Redraws progress bar to fit new terminal dimensions | - |

Exit codes follow the convention `128 + signal_number`:

| Signal | Number | Exit code |
|--------|--------|-----------|
| SIGHUP  | 1  | 129 |
| SIGINT  | 2  | 130 |
| SIGQUIT | 3  | 131 |
| SIGTERM | 15 | 143 |
| SIGTSTP | 20 | 148 |

Child processes are tracked by PID and terminated individually during cleanup, so only processes spawned by the script are affected - no other system processes are touched, and the same idempotent cleanup runs on both signal handling and the normal exit path.

---

## State files

After launching an attack, state files are stored per-host in `.getsshpass/<host>/` inside the script directory, so results from different targets don't overwrite each other:

| File | Purpose |
|------|---------|
| `.getsshpass/` | Root state directory, auto-created inside the script directory and gitignored. Holds one subdirectory per target host so different targets never collide; can be deleted manually to wipe all state. |
| `.getsshpass/<host>/` | Per-host subdirectory, named after the target hostname or IP. Created automatically on the first run against that host and reused on subsequent runs. |
| `filter_tmp/` | Transient directory used during user filtering. Each parallel probe creates a file named after the username (e.g. `filter_tmp/root`) containing the username, only if that user has password authentication enabled. Users that only accept key-based auth get no file. Once all probes finish, the script checks for file existence to rebuild `filtered_users.txt` in original order, then deletes `filter_tmp/`. If interrupted mid-filter the directory is left behind, but the next run removes it at the start of filtering. |
| `filtered_users.txt` | Usernames with password authentication enabled, generated during the filtering step and reused on subsequent runs if present |
| `result.txt` | Found credentials, written on success |
| `resume.txt` | Last attempted `username\tpassword` pair (tab-separated), written before each attempt |
| `skipped.txt` | User/password pairs whose retries were exhausted (typically an OpenSSH 9.8+ `PerSourcePenalties` block dropping the connection). Retried serially in a second pass at the end of the run; any that still fail remain here and the result is reported as inconclusive. Deleted on success. |

---

## Run lifecycle

Across runs, the per-host state files carry progress through interruption, resumption, and completion:

- **On interruption** (Ctrl+C, Ctrl+Z, or kill signal), the script cleans up child processes and exits. The `resume.txt` file remains with the last attempted credentials, so the next run can pick up from exactly where it stopped instead of starting over.
- **On next run**, the script detects `resume.txt`, parses the tab-separated `username\tpassword` pair it holds, and resumes the attack from that point, retrying the last attempted pair first, then continuing with the remaining entries.

  The pair is tab-separated (rather than colon) so usernames and passwords containing colons are handled correctly. It looks up each value with `grep -Fxn` (literal, full-line match) to find the line number, then uses `tail -n +<line>` (print from line N to end of file, skipping everything before it) to write trimmed copies as temporary `.new` files next to the originals (e.g. `rockyou.txt` → `rockyou.txt.new`). If the saved username is not found in the user list, a warning is emitted and the entire attack restarts from the beginning of both lists. If the saved password is not found (but the username was), a warning is emitted and only the password list restarts from the beginning for that username. The `.new` files are cleaned up automatically on any exit.
- **On success**, `result.txt` is written with the found credentials. If the script is run again to the same host while `result.txt` exists in its folder, it shows the saved password and asks whether to run again:

  ```
  Warning: Previous result found for '192.168.1.1': user 'admin', password 'admin'
  Run again anyway? [y/N]
  ```

  Answering `y` clears state files for that host and starts a fresh attack. Answering `N` (or Enter) exits.

---

## Clearing state

Use the `-c/--clear` flag to delete state files, or remove the `.getsshpass/` directory manually. When combined with the `-a/--attack` flag, only that host's state is cleared. Without `-a`, state for all hosts is removed:

```bash
./getsshpass.sh --clear --attack 192.168.1.1   # clear state for one host
./getsshpass.sh --clear                        # clear state for all hosts
rm -rf .getsshpass/                            # manual alternative
```

---

[← Back to the README](../README.md)
