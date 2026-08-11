#!/usr/bin/env bats
#
# Unit tests for the pure-bash helper functions in getsshpass.sh.
# The script is sourced (not executed) thanks to the BASH_SOURCE guard
# around main, so these functions can be called directly.

setup() {
  source "${BATS_TEST_DIRNAME}/../src/getsshpass.sh"
  # The script enables `set -u`/pipefail globally; relax them so they do
  # not interfere with the Bats framework between assertions.
  set +u +o pipefail
}

@test "format_number: inserts thousands separators" {
  format_number 1234567 out
  [ "${out}" = "1,234,567" ]
}

@test "format_number: leaves short numbers unchanged" {
  format_number 42 out
  [ "${out}" = "42" ]
}

@test "format_number: handles an exact thousand" {
  format_number 1000 out
  [ "${out}" = "1,000" ]
}

@test "sleep_ms: formats milliseconds as decimal seconds" {
  sleep() { printf '%s' "${1}"; }  # stub the real sleep to capture its arg
  run sleep_ms 1600
  [ "${output}" = "1.600" ]
}

@test "sleep_ms: pads sub-second values" {
  sleep() { printf '%s' "${1}"; }
  run sleep_ms 50
  [ "${output}" = "0.050" ]
}

@test "validate_port: accepts 22" {
  port=22
  run validate_port
  [ "${status}" -eq 0 ]
}

@test "validate_port: rejects 0" {
  port=0
  run validate_port
  [ "${status}" -ne 0 ]
}

@test "validate_port: rejects out-of-range 70000" {
  port=70000
  run validate_port
  [ "${status}" -ne 0 ]
}

@test "validate_host: accepts a valid IPv4 address" {
  host=192.168.1.10
  run validate_host
  [ "${status}" -eq 0 ]
}

@test "validate_host: rejects an octet greater than 255" {
  host=192.168.1.300
  run validate_host
  [ "${status}" -ne 0 ]
}

@test "validate_host: bracket-wraps an IPv6 address" {
  host=2001:db8::1
  validate_host
  [ "${ssh_host}" = "[2001:db8::1]" ]
}

# restore_progress recomputes the attempt counter from the resume point.
# Set up small lists and a resume marker, then check the derived `attempt`.

@test "restore_progress: users-first resume offset" {
  local d; d="$(mktemp -d)"
  printf 'u1\nu2\nu3\n'     > "${d}/u.txt"
  printf 'p1\np2\np3\np4\n' > "${d}/p.txt"
  printf 'u2\tp3\n'         > "${d}/resume.txt"
  first_flag=u
  userlist="${d}/u.txt"; passlist="${d}/p.txt"
  fulluserlist="${d}/u.txt"; fullpasslist="${d}/p.txt"
  userlist_orig="${d}/u.txt"; passlist_orig="${d}/p.txt"
  RESUME_FILE="${d}/resume.txt"
  attempt=0
  restore_progress >/dev/null 2>&1
  # u1*4 + u2*(p1,p2) = 6 pairs already tried before u2/p3
  [ "${attempt}" -eq 6 ]
  rm -rf "${d}"
}

@test "restore_progress: password-spray resume offset" {
  local d; d="$(mktemp -d)"
  printf 'u1\nu2\nu3\n' > "${d}/u.txt"
  printf 'p1\np2\n'     > "${d}/p.txt"
  printf 'u2\tp1\n'     > "${d}/resume.txt"
  first_flag=d
  userlist="${d}/u.txt"; passlist="${d}/p.txt"
  fulluserlist="${d}/u.txt"; fullpasslist="${d}/p.txt"
  userlist_orig="${d}/u.txt"; passlist_orig="${d}/p.txt"
  RESUME_FILE="${d}/resume.txt"
  attempt=0
  restore_progress >/dev/null 2>&1
  # spray p1 across users: p1/u1 = 1 pair tried before p1/u2
  [ "${attempt}" -eq 1 ]
  rm -rf "${d}"
}
