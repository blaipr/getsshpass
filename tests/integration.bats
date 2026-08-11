#!/usr/bin/env bats
#
# End-to-end tests that drive getsshpass.sh with a stub `ssh` on PATH,
# simulating OpenSSH 9.8+ PerSourcePenalties (connection drops) to exercise
# the skip / second-pass / inconclusive logic without a live SSH server.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/getsshpass.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  cp "${SCRIPT}" "${WORK}/getsshpass.sh"
  printf 'blai\n' > "${WORK}/users.txt"
  printf 'secret1\n' > "${WORK}/pass.txt"

  # Stub ssh. Behaviour is selected by $FAKE_MODE:
  #   drop     - every attack connection is dropped (exit 255, no auth error)
  #   recover  - first 4 attack calls drop, then the correct password succeeds
  #   adminwin - the admin:admin pre-flight check succeeds immediately
  cat > "${WORK}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "${args}" in *-V*) echo "OpenSSH_9.8p1" >&2; exit 0;; esac
target=""; for a in "$@"; do case "${a}" in *@*) target="${a}";; esac; done
case "${args}" in
  *BatchMode=yes*) echo "${target}: (password,keyboard-interactive)." >&2; exit 255;;
esac
case "${target}" in
  admin@*)
    [ "${FAKE_MODE}" = adminwin ] && exit 0
    echo "Permission denied" >&2; exit 5;;
esac
case "${FAKE_MODE}" in
  recover)
    n=$(( $(cat "${FAKE_COUNTER}" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${FAKE_COUNTER}"
    if [ "${n}" -le 4 ]; then
      echo "kex_exchange_identification: Connection closed" >&2; exit 255
    fi
    [ "${SSH_PASSWORD}" = secret1 ] && exit 0
    echo "Permission denied" >&2; exit 255;;
  *)
    echo "kex_exchange_identification: Connection closed" >&2; exit 255;;
esac
STUB
  chmod +x "${WORK}/bin/ssh"
}

teardown() {
  rm -rf "${WORK}"
}

# Run the tool against the stub. Extra args are passed through.
run_tool() {
  run bash -c "PATH='${WORK}/bin:${PATH}' FAKE_MODE='${FAKE_MODE}' \
    FAKE_COUNTER='${WORK}/cnt' bash '${WORK}/getsshpass.sh' \
    -a 127.0.0.1 -u '${WORK}/users.txt' -d '${WORK}/pass.txt' $* </dev/null"
}

@test "dropped connections leave the pair untested and report INCONCLUSIVE" {
  FAKE_MODE=drop
  run_tool -r 2 -j 1 -w 0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *INCONCLUSIVE* ]]
  [ -f "${WORK}/.getsshpass/127.0.0.1/skipped.txt" ]
  grep -q $'blai\tsecret1' "${WORK}/.getsshpass/127.0.0.1/skipped.txt"
}

@test "a pair skipped in the main run is recovered on the second pass" {
  FAKE_MODE=recover
  run_tool -r 3 -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Found username: 'blai' and password: 'secret1'"* ]]
  [ ! -f "${WORK}/.getsshpass/127.0.0.1/skipped.txt" ]
}

@test "admin:admin is found by the pre-flight check" {
  FAKE_MODE=adminwin
  run_tool -r 1 -j 1 -w 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"username: 'admin' and password: 'admin'"* ]]
}

@test "startup advisory warns about PerSourcePenalties on unlimited jobs" {
  FAKE_MODE=drop
  run_tool -r 1 -w 0
  [[ "${output}" == *PerSourcePenalties* ]]
}

@test "no PerSourcePenalties advisory with a small job cap" {
  FAKE_MODE=drop
  run_tool -r 1 -j 2 -w 0
  [[ "${output}" != *PerSourcePenalties* ]]
}
