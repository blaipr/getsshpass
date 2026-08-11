# Troubleshooting

Common problems and their fixes, from startup errors to inconclusive results. Each entry quotes the message you would see and explains what to do about it. If your issue isn't listed, re-run with a single job and a delay (`-j 1 -w 5`) to rule out rate limiting, and confirm the target actually allows password authentication.

**Contents**

- [Startup and dependency errors](#startup-and-dependency-errors)
- [Connection failures](#connection-failures)
- [No users to attack](#no-users-to-attack)
- [Inconclusive results and connection penalties](#inconclusive-results-and-connection-penalties)
- [Wordlist downloads](#wordlist-downloads)
- [Resume, caching, and starting over](#resume-caching-and-starting-over)

---

## Startup and dependency errors

**`getsshpass requires bash 4.4 or newer`** - The script uses features (safe empty-array expansion under `set -u`, `printf '%(...)T'`) that need bash 4.4+. macOS ships bash 3.2, so install a newer one and make sure it is first on your `PATH`:

```bash
brew install bash
```

**`OpenSSH X.Y detected; SSH_ASKPASS_REQUIRE=force requires OpenSSH 8.4+`** - The default password-delivery mode needs OpenSSH 8.4 or newer. Either upgrade the OpenSSH client, or switch to sshpass mode:

```bash
./getsshpass.sh -a <host> -u users.txt -d rockyou.txt -s
```

**`Utility 'ssh' not found`** / **`Utility 'sshpass' not found`** / **`Utility 'curl' not found`** - The named tool is missing. Install `openssh-client` for `ssh`, `sshpass` for `-s/--sshpass` mode, or `curl` for `--fetch`, using your package manager.

---

## Connection failures

**`Cannot establish SSH connection to '<host>:<port>'`** - The pre-flight check could not reach the target at all. Confirm the host is up, the port is correct (`-p`), and nothing (firewall, network) is blocking you.

Behind the scenes, SSH exits with 255 for both a bad password and a real connection error; getsshpass reads stderr to tell them apart (see [How it works](how-it-works.md#1-connection-check)). A genuine connection error stops the run, while a `Permission denied` lets the attack proceed.

---

## No users to attack

**`[WARN ] No users with password authentication found`** - Before attacking, getsshpass probes every username with `ssh -o BatchMode=yes` and keeps only those whose server offers password (or keyboard-interactive) authentication. If none qualify, there is nothing to brute-force and the run exits.

Usually this means the target only accepts key-based logins, or your username list doesn't match any real accounts. Confirm the server actually permits password authentication (`PasswordAuthentication yes` in its `sshd_config`) and that the usernames are plausible.

---

## Inconclusive results and connection penalties

**`... could not be tested ... result is INCONCLUSIVE`** - Some username/password pairs were never actually tested because the server kept dropping the connection - almost always an OpenSSH 9.8+ `PerSourcePenalties` block, which temporarily bans a source IP after repeated failures. The untested pairs are saved to `skipped.txt`.

getsshpass already retries those pairs serially in a second pass, but if the penalty is still active they stay untested and the result is reported as inconclusive rather than a false "not found". Re-run with gentler settings so you stay under the penalty threshold:

```bash
./getsshpass.sh -a <host> -u users.txt -d rockyou.txt -j 1 -w 5
```

On a target you are authorized to reconfigure, disabling `PerSourcePenalties` in its `sshd_config` also removes the limit. See [How it works](how-it-works.md#4-dictionary-attack) for the mechanism.

---

## Wordlist downloads

**`Checksum mismatch for '<file>'`** - A `--fetch` download did not match the SHA-256 pinned in the catalog, so the partial file was deleted and the fetch failed. Re-run it (the download may have been truncated); if it keeps failing, the pinned hash in `wordlists.txt` may be stale for a URL whose contents changed. See [Wordlists](wordlists.md#adding-wordlists).

**`File '<file>' already exists, skipping`** - `--fetch` will not overwrite an existing file. Delete or rename it first if you want a fresh copy.

---

## Resume, caching, and starting over

**`Found resume file ... Restoring progress...`** - A previous run was interrupted, so getsshpass picked up from the last attempted pair recorded in `resume.txt`. This is normal; to start from the beginning instead, clear the state first (below).

**`Reuse cached list? [Y/n]`** - A `filtered_users.txt` from an earlier run against this host exists. Answer `Y` (default) to skip re-probing users, or `n` to filter again from scratch.

**`Warning: Previous result found ... Run again anyway? [y/N]`** - A password was already found for this host (stored in `result.txt`). Answer `y` to discard it and start a fresh attack, or `N`/Enter to keep the result and exit.

To wipe saved state and start completely fresh:

```bash
./getsshpass.sh --clear --attack <host>   # one host
./getsshpass.sh --clear                    # all hosts
```

See [State and resume](state-and-resume.md) for the full state-file layout.

---

[← Back to the README](../README.md)
