# Testing

Unit and integration tests use [bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System, a TAP-compliant testing framework for Bash).

Run the whole suite with:

```
bats tests/
```

No live SSH server is needed: the integration tests put a stub `ssh` on `PATH` that simulates connection outcomes, including OpenSSH 9.8+ `PerSourcePenalties` drops. CI runs `bash -n`, ShellCheck, and the full test suite on every push and pull request, across both Linux and macOS runners, so regressions are caught before they merge.

**Contents**

- [Unit tests](#unit-tests)
- [Integration tests](#integration-tests)
- [Argument and validation tests](#argument-and-validation-tests)
- [Download tests](#download-tests)

---

## Unit tests

`tests/helpers.bats` — the script is sourced without running `main`, so pure functions can be called directly:

- `format_number` inserts thousands separators and leaves short numbers unchanged
- `sleep_ms` formats milliseconds as the decimal seconds `sleep` expects
- `validate_port` accepts valid ports and rejects `0` and out-of-range values
- `validate_host` accepts IPv4, rejects octets above 255, and bracket-wraps IPv6
- `restore_progress` recomputes the attempt offset correctly for both attack orders

---

## Integration tests

`tests/integration.bats` — each test drives the script end to end against a stub `ssh`/`sshpass`, so no live SSH server is involved:

- A dropped connection is recorded to `skipped.txt` and reported as an `INCONCLUSIVE` result, and a pair that was skipped during the parallel main run is recovered on the serial second pass once the connection flood subsides.
- The `admin:admin` quick-win is caught by the pre-flight connection check, and the `PerSourcePenalties` startup advisory appears when parallelism is unlimited but is suppressed as soon as a small `-j` job cap is set.
- `sshpass` mode, multiple `-u` and `-d` files concatenated in order, CRLF (`\r\n`) line endings, IPv6 bracket-wrapping of the target, and password-spray order (`-d` before `-u`) all drive a successful run end to end.
- Users without password authentication are filtered out — and the run exits cleanly when none qualify — while interrupted runs resume from `resume.txt` and an existing result prompts for confirmation before starting over.

---

## Argument and validation tests

`tests/args.bats` — the early-exit paths in `read_args` and `check_args`, which need no live connection:

- Unrecognized options and options that are missing their argument (for example `-p` with nothing after it, or a bare `-a`) are rejected up front with a clear error message and a non-zero exit status, before any connection is attempted.
- Out-of-range numeric flags are caught during validation before the attack begins: a non-numeric `-j`, a zero or non-numeric `-r`, and a non-numeric `-w` each abort the run immediately with a descriptive, flag-specific error message.
- Missing, unreadable, or empty username and password files are all reported together in a single pass, and `--clear` wipes saved state for one host when given `-a`, or for every host at once when no target is supplied.

---

## Download tests

`tests/download.bats` — `--fetch` exercised over a local `file://` URL, so no network is touched:

- A download whose pinned SHA-256 matches the catalog is kept, while a checksum mismatch deletes the partially downloaded file and fails the run, so a tampered, corrupted, or truncated wordlist can never be left behind on disk.
- Catalog entries that pin no checksum still download successfully, which keeps the SHA-256 field strictly optional while any entry that does pin a hash stays verified end to end on every fetch.

---

[← Back to the README](../README.md)
