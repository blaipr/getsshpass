#!/usr/bin/env bats
#
# Tests for `--fetch` wordlist downloading and optional SHA-256 verification.
# A local file:// URL stands in for the remote wordlist, so no network is used.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/getsshpass.sh"
  WORK="$(mktemp -d)"
  cp "${SCRIPT}" "${WORK}/getsshpass.sh"
  printf 'password1\npassword2\n' > "${WORK}/fixture.txt"
  if command -v sha256sum >/dev/null 2>&1; then
    SHA="$(sha256sum "${WORK}/fixture.txt" | cut -d' ' -f1)"
  else
    SHA="$(shasum -a 256 "${WORK}/fixture.txt" | cut -d' ' -f1)"
  fi
}

teardown() {
  rm -rf "${WORK}"
}

# Run `getsshpass.sh -f NAME` from WORK, so SCRIPT_DIR (and the catalog) is WORK.
fetch() {
  run bash -c "cd '${WORK}' && bash ./getsshpass.sh -f '$1' </dev/null"
}

@test "download succeeds when the pinned SHA-256 matches" {
  printf 'good|out.txt|test|file://%s/fixture.txt|%s\n' "${WORK}" "${SHA}" \
    > "${WORK}/wordlists.txt"
  fetch good
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/out.txt" ]
}

@test "download fails and file is removed when the SHA-256 mismatches" {
  printf 'bad|out.txt|test|file://%s/fixture.txt|deadbeef\n' "${WORK}" \
    > "${WORK}/wordlists.txt"
  fetch bad
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Checksum mismatch"* ]]
  [ ! -f "${WORK}/out.txt" ]
}

@test "download succeeds without verification when no SHA-256 is pinned" {
  printf 'none|out.txt|test|file://%s/fixture.txt\n' "${WORK}" \
    > "${WORK}/wordlists.txt"
  fetch none
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/out.txt" ]
}
