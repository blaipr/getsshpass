# Wordlists

A wordlist (also called a dictionary) is a plain text file containing one candidate entry per line - usernames or passwords. The tool systematically tries every username/password combination from these lists against the target.

**Contents**

- [Wordlist format](#wordlist-format)
- [Downloading wordlists](#downloading-wordlists)
- [Adding wordlists](#adding-wordlists)

---

## Wordlist format

Empty lines are skipped automatically. Windows line endings (`\r\n`) are handled transparently. Files should end with a trailing newline, though the last line is processed either way.

---

## Downloading wordlists

I added built-in wordlist downloading so you don't have to search for them. Available wordlists are defined in `src/wordlists.txt` (see [File structure](../README.md#file-structure)). Use `-l`/`--list` to see what's available and `-f`/`--fetch` to download:

```bash
./getsshpass.sh --list                    # show available wordlists
./getsshpass.sh --fetch top-usernames     # top-usernames-shortlist.txt - 17 top usernames, 1 KB
./getsshpass.sh --fetch rockyou           # rockyou.txt - 14.3M passwords, 134 MB
./getsshpass.sh --fetch 10k               # 10k-most-common.txt - 10,000 passwords, 71 KB
./getsshpass.sh --fetch 100k              # 100k-passwords.txt - 100,000 passwords, 816 KB
./getsshpass.sh -f 10k -f 100k            # fetch multiple at once
```

Wordlists are downloaded to the current directory. If the file already exists, the download is skipped. Requires `curl`; when a catalog entry pins a `SHA256`, the download is verified with `sha256sum`/`shasum` and removed on mismatch.

---

## Adding wordlists

To add your own wordlists, edit `src/wordlists.txt` and add one line per wordlist using this format:

```
NAME|FILENAME|DESCRIPTION|URL|SHA256
```

- **NAME** - Short identifier used with `-f/--fetch` (e.g. `rockyou`)
- **FILENAME** - Local filename to save as (e.g. `rockyou.txt`)
- **DESCRIPTION** - Brief description shown by `--list` (e.g. `14.3M passwords, 134 MB`)
- **URL** - Direct download URL for the wordlist
- **SHA256** - Optional. When present, the download is verified against this digest and deleted on mismatch. Pin it only for immutable URLs (release assets), not mutable branch URLs whose content can change.

---

[← Back to the README](../README.md)
