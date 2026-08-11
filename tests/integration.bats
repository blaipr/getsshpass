#!/usr/bin/env bats
#
# End-to-end tests that drive getsshpass.sh with stub `ssh`/`sshpass` binaries
# on PATH, simulating connection outcomes (including OpenSSH 9.8+
# PerSourcePenalties drops) so no live SSH server is required.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/getsshpass.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  cp "${SCRIPT}" "${WORK}/getsshpass.sh"
  printf 'blai\n' > "${WORK}/users.txt"
  printf 'secret1\n' > "${WORK}/pass.txt"

  # Stub ssh. $FAKE_MODE selects behaviour:
  #   drop     - every attack connection is dropped (exit 255, no auth error)
  #   recover  - first 4 attack calls drop, then the good credential succeeds
  #   adminwin - the admin:admin pre-flight check succeeds
  #   (unset)  - a connection succeeds when the user/pass match FAKE_GOOD_*
  cat > "${WORK}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "${args}" in *-V*) echo "OpenSSH_9.8p1" >&2; exit 0;; esac
target=""; for a in "$@"; do case "${a}" in *@*) target="${a}";; esac; done
case "${args}" in
  *BatchMode=yes*)
    u="${target%@*}"
    for nu in ${FAKE_NOAUTH_USERS:-}; do
      [ "${u}" = "${nu}" ] && { echo "${target}: Permission denied (publickey)." >&2; exit 255; }
    done
    echo "${target}: (password,keyboard-interactive)." >&2; exit 255;;
esac
case "${target}" in
  admin@*)
    [ "${FAKE_MODE:-}" = adminwin ] && exit 0
    echo "Permission denied" >&2; exit 5;;
esac
match() {
  local u="${target%@*}"
  [ -n "${FAKE_GOOD_USER:-}" ] && [ "${u}" != "${FAKE_GOOD_USER}" ] && return 1
  [ "${SSH_PASSWORD}" = "${FAKE_GOOD_PASS:-secret1}" ]
}
case "${FAKE_MODE:-}" in
  drop) echo "kex_exchange_identification: Connection closed" >&2; exit 255;;
  recover)
    n=$(( $(cat "${FAKE_COUNTER}" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${FAKE_COUNTER}"
    if [ "${n}" -le 4 ]; then
      echo "kex_exchange_identification: Connection closed" >&2; exit 255
    fi
    match && exit 0
    echo "Permission denied" >&2; exit 255;;
  *)
    match && exit 0
    echo "Permission denied, please try again." >&2; exit 255;;
esac
STUB
  chmod +x "${WORK}/bin/ssh"

  # Stub sshpass: `sshpass -p PASS ssh ...`. Succeeds on a matching password.
  cat > "${WORK}/bin/sshpass" <<'STUB'
#!/usr/bin/env bash
pass=""
[ "$1" = "-p" ] && { pass="$2"; shift 2; }
target=""; for a in "$@"; do case "${a}" in *@*) target="${a}";; esac; done
case "${target}" in
  admin@*) [ "${FAKE_MODE:-}" = adminwin ] && exit 0; exit 5;;
esac
[ "${pass}" = "${FAKE_GOOD_PASS:-secret1}" ] && exit 0
exit 5
STUB
  chmod +x "${WORK}/bin/sshpass"
}

teardown() {
  rm -rf "${WORK}"
}

# Run the tool with the given args under the stub environment (stdin closed).
gsp() {
  run bash -c "PATH='${WORK}/bin:${PATH}' \
    FAKE_MODE='${FAKE_MODE:-}' FAKE_COUNTER='${WORK}/cnt' \
    FAKE_GOOD_USER='${FAKE_GOOD_USER:-}' FAKE_GOOD_PASS='${FAKE_GOOD_PASS:-}' \
    FAKE_NOAUTH_USERS='${FAKE_NOAUTH_USERS:-}' \
    bash '${WORK}/getsshpass.sh' $* </dev/null"
}

@test "dropped connections leave the pair untested and report INCONCLUSIVE" {
  FAKE_MODE=drop
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -r 2 -j 1 -w 0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *INCONCLUSIVE* ]]
  [ -f "${WORK}/.getsshpass/127.0.0.1/skipped.txt" ]
  grep -q $'blai\tsecret1' "${WORK}/.getsshpass/127.0.0.1/skipped.txt"
}

@test "a pair skipped in the main run is recovered on the second pass" {
  FAKE_MODE=recover
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -r 3 -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
  [ ! -f "${WORK}/.getsshpass/127.0.0.1/skipped.txt" ]
}

@test "admin:admin is found by the pre-flight check" {
  FAKE_MODE=adminwin
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -r 1 -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"username: 'admin' and password: 'admin'"* ]]
}

@test "startup advisory warns about PerSourcePenalties on unlimited jobs" {
  FAKE_MODE=drop
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -r 1 -w 0
  [[ "${output}" == *PerSourcePenalties* ]]
}

@test "no PerSourcePenalties advisory with a small job cap" {
  FAKE_MODE=drop
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -r 1 -j 2 -w 0
  [[ "${output}" != *PerSourcePenalties* ]]
}

@test "sshpass mode (-s) finds the password" {
  gsp -s -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
}

@test "multiple -u files are concatenated (winning user in the second file)" {
  printf 'alice\n' > "${WORK}/u1.txt"
  printf 'blai\n'  > "${WORK}/u2.txt"
  FAKE_GOOD_USER=blai
  gsp -a 127.0.0.1 -u "${WORK}/u1.txt" -u "${WORK}/u2.txt" -d "${WORK}/pass.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
}

@test "CRLF line endings in wordlists are handled" {
  printf 'blai\r\n'    > "${WORK}/users_crlf.txt"
  printf 'secret1\r\n' > "${WORK}/pass_crlf.txt"
  FAKE_GOOD_USER=blai
  gsp -a 127.0.0.1 -u "${WORK}/users_crlf.txt" -d "${WORK}/pass_crlf.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
}

@test "IPv6 target is bracket-wrapped end to end" {
  gsp -a 2001:db8::1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[2001:db8::1]:22"* ]]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
}

@test "users without password auth are filtered out" {
  printf 'alice\nblai\n' > "${WORK}/users2.txt"
  FAKE_NOAUTH_USERS=alice
  FAKE_GOOD_USER=blai
  gsp -a 127.0.0.1 -u "${WORK}/users2.txt" -d "${WORK}/pass.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1/2 users allow password authentication"* ]]
  [[ "${output}" == *"Found username: 'blai'"* ]]
}

@test "no users with password auth exits without attacking" {
  FAKE_NOAUTH_USERS=blai
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/pass.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No users with password authentication found"* ]]
}

@test "multiple -d files are concatenated (winning pass in the second file)" {
  printf 'wrongpass\n' > "${WORK}/d1.txt"
  printf 'winpass\n'   > "${WORK}/d2.txt"
  FAKE_GOOD_PASS=winpass
  gsp -a 127.0.0.1 -u "${WORK}/users.txt" -d "${WORK}/d1.txt" -d "${WORK}/d2.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"and password: 'winpass'"* ]]
}

@test "an interrupted run resumes from resume.txt" {
  printf 'u1\nu2\nu3\n' > "${WORK}/ru.txt"
  printf 'p1\np2\n'     > "${WORK}/rp.txt"
  mkdir -p "${WORK}/.getsshpass/127.0.0.1"
  printf 'u2\tp1\n'     > "${WORK}/.getsshpass/127.0.0.1/resume.txt"
  FAKE_GOOD_USER=u3
  FAKE_GOOD_PASS=p2
  gsp -a 127.0.0.1 -u "${WORK}/ru.txt" -d "${WORK}/rp.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Restoring progress"* ]]
  [[ "${output}" == *"Found username: 'u3' and password: 'p2'"* ]]
}

@test "password-spray order (-d before -u) is used" {
  FAKE_GOOD_PASS=secret1
  gsp -a 127.0.0.1 -d "${WORK}/pass.txt" -u "${WORK}/users.txt" -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"passwords first (spray)"* ]]
  [[ "${output}" == *"Found username: 'blai'"* ]]
}

@test "an existing result prompts and exits when declined" {
  mkdir -p "${WORK}/.getsshpass/127.0.0.1"
  printf "Found username: 'blai' and password: 'secret1'\n" \
    > "${WORK}/.getsshpass/127.0.0.1/result.txt"
  run bash -c "printf 'n\n' | PATH='${WORK}/bin:${PATH}' FAKE_GOOD_PASS=secret1 \
    bash '${WORK}/getsshpass.sh' -a 127.0.0.1 -u '${WORK}/users.txt' -d '${WORK}/pass.txt' -j 1 -w 0"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Previous result found"* ]]
}
