#!/usr/bin/env bats
#
# Argument parsing, input validation, and state-clearing tests. These exercise
# the early-exit paths in read_args/check_args, so a minimal ssh stub (just a
# modern version string) is enough.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/getsshpass.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  cp "${SCRIPT}" "${WORK}/getsshpass.sh"
  printf 'blai\n' > "${WORK}/users.txt"
  printf 'secret1\n' > "${WORK}/pass.txt"
  cat > "${WORK}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *-V*) echo "OpenSSH_9.8p1" >&2; exit 0;; esac
exit 0
STUB
  chmod +x "${WORK}/bin/ssh"
}

teardown() { rm -rf "${WORK}"; }

gsp() {
  run bash -c "PATH='${WORK}/bin:${PATH}' bash '${WORK}/getsshpass.sh' $* </dev/null"
}

@test "unknown option is rejected" {
  gsp -Z
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown option"* ]]
}

@test "option missing its argument is rejected" {
  gsp -p
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires an argument"* ]]
}

@test "invalid -j (jobs) is rejected" {
  gsp -a 127.0.0.1 -j abc
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"parallel jobs"* ]]
}

@test "invalid -r (retries) is rejected" {
  gsp -a 127.0.0.1 -r 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"retries"* ]]
}

@test "invalid -w (wait) is rejected" {
  gsp -a 127.0.0.1 -w abc
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Delay"* ]]
}

@test "missing password file is reported" {
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/nope.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Cannot find password file"* ]]
}

@test "missing username file is reported" {
  gsp -a 127.0.0.1 -u "${WORK}/nope.txt" -d "${WORK}/pass.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Cannot find username file"* ]]
}

@test "empty wordlist file is reported" {
  : > "${WORK}/empty.txt"
  gsp -a 127.0.0.1 -u "${WORK}/empty.txt" -d "${WORK}/pass.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"empty"* ]]
}

@test "--clear removes a single host's state" {
  mkdir -p "${WORK}/.getsshpass/127.0.0.1"
  : > "${WORK}/.getsshpass/127.0.0.1/result.txt"
  gsp --clear --attack 127.0.0.1
  [ "${status}" -eq 0 ]
  [ ! -d "${WORK}/.getsshpass/127.0.0.1" ]
}

@test "--clear without a host removes all state" {
  mkdir -p "${WORK}/.getsshpass/hostA" "${WORK}/.getsshpass/hostB"
  gsp --clear
  [ "${status}" -eq 0 ]
  [ ! -d "${WORK}/.getsshpass" ]
}
