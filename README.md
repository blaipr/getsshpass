# getsshpass

A dictionary-based SSH password auditing tool for authorized security testing.

Originally created in 2016 by [Radovan Brezula](https://brezular.com/2016/01/11/bash-script-for-dictionary-attack-against-ssh-server/) as a proof-of-concept SSH brute-forcer. I (Blai Peidro) joined the project that same year and have since completely rewritten the codebase with security hardening, improved resume support, parallel job control, signal-safe process cleanup, and modern bash practices.

In benchmarks against a local host, getsshpass found a password at row 5,000 of `rockyou.txt` (14.3M lines) in approximately 3 min 29 sec - outperforming THC Hydra (4 min 45 sec with its maximum 64 parallel sessions) using sshpass with only 5 parallel jobs and a 0.04s delay between attempts on the same target.

---

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

---

## File structure

Repository layout:

```
getsshpass/
├── .github/         # GitHub Actions CI, issue/PR templates, and Dependabot config
├── docs/            # In-depth documentation guides
├── src/             # The getsshpass.sh script, wordlist catalog, and runtime state
├── tests/           # bats unit and integration test suites
├── .editorconfig    # Editor settings (2-space indent, 80 cols)
├── .shellcheckrc    # ShellCheck configuration
├── CHANGELOG.md     # Version history
├── CONTRIBUTING.md  # Contribution guidelines
├── LICENSE          # GPLv3+ license
├── README.md        # This file
└── SECURITY.md      # Security policy and responsible-use notice
```

---

## Requirements

- Bash 4.4+ (checked at startup)
- ssh (OpenSSH 8.4+ client required for default SSH_ASKPASS mode; any version works with `-s/--sshpass`)
- curl (optional, for `--fetch` wordlist feature)
- sshpass (optional, for `-s/--sshpass` mode)
- sha256sum or shasum (optional, to verify `--fetch` downloads that pin a checksum)

The script verifies it is running on bash 4.4 or newer and exits with a clear message otherwise (macOS ships bash 3.2 — install a newer bash with `brew install bash`). It also checks for `ssh` at startup and exits with a clear error if it is missing. When using the default SSH_ASKPASS mode, it also checks that the OpenSSH client is version 8.4 or newer (required for `SSH_ASKPASS_REQUIRE=force`) and exits with an error directing the user to `-s/--sshpass` if not.

If `-s/--sshpass` is used, the script checks for `sshpass` at startup and exits if it is missing.

---

## Documentation

In-depth guides live in the [`docs/`](docs/) folder:

- [Usage](docs/usage.md) - steps, all options, examples, and sample output
- [How it works](docs/how-it-works.md) - the SSH_ASKPASS and sshpass mechanisms, the attack loop, and performance tuning
- [Wordlists](docs/wordlists.md) - wordlist format, and fetching or adding lists (`--fetch`/`--list`)
- [State and resume](docs/state-and-resume.md) - signal handling, per-host state files, and resuming interrupted runs
- [Troubleshooting](docs/troubleshooting.md) - common errors and messages, and how to fix them
- [Testing](docs/testing.md) - running the unit and integration suites

---

## Code style

This project follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html). See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Authors

- **Radovan Brezula** ([brezular](https://brezular.com)) - original author
- **Blai Peidro** - co-author

---

## License

GPLv3+ - GNU General Public License version 3 or later.
See [LICENSE](LICENSE) for details.

---

## Disclaimer

This tool is intended for **authorized security auditing and penetration testing only**. Unauthorized access to computer systems is illegal. Always obtain proper written authorization before testing any system you do not own.
