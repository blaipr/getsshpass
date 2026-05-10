# Contributing

Thanks for your interest in contributing to getsshpass!

## How to contribute

1. **Fork** the repository
2. **Create a branch** for your change (`git checkout -b my-improvement`)
3. **Check syntax** with `bash -n getsshpass.sh` and lint with [ShellCheck](https://www.shellcheck.net/)
4. **Test** your changes against a local SSH server you control
5. **Submit a pull request** with a clear description of what you changed and why

## Guidelines

This project follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html). Key points:

- Keep it simple - this is a single bash script, not a framework
- Test on both Linux and macOS if possible
- Indent with **2 spaces**, no tabs
- Maximum line length is **80 characters**
- Always use `${var}` (braces) for variable references, not bare `$var`
- Quote all variables (use [ShellCheck](https://www.shellcheck.net/) to verify)
- Use `[[ ]]` for conditionals and `(( ))` for arithmetic
- Use `printf` instead of `echo -e`
- Use `$(command)` instead of backticks for command substitution
- Use `msg_info`, `msg_ok`, `msg_warn`, `msg_fail` for output
- `msg_fail`/`msg_warn` go to **stderr**; `msg_ok`/`msg_info` to stdout
- New flags need short (`-x`) and long (`--name`) forms in `read_args()`
- Don't add dependencies beyond standard coreutils + `sshpass` + `ssh`

## Reporting issues

Open a GitHub issue with:

- What you expected to happen
- What actually happened
- Your OS and bash version (`bash --version`)
- The command you ran (redact any real credentials or target addresses)

## Legal

By contributing, you agree that your contributions will be licensed under the [GPLv3+](LICENSE).

## Security

This tool is for **authorized security testing only**. Do not submit features designed to evade detection or bypass security controls. Contributions should help defenders audit their own systems.
