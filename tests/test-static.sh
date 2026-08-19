#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/setvps.sh"

bash -n "${SCRIPT}"

assert_contains() {
  local text="$1"
  grep -Fq "${text}" "${SCRIPT}" || {
    printf 'missing required contract: %s\n' "${text}" >&2
    exit 1
  }
}

assert_contains 'PasswordAuthentication yes'
assert_contains 'PermitRootLogin yes'
assert_contains '/swapfile none swap sw 0 0'
assert_contains '1|2|4)'
assert_contains 'configure_swap 1'
assert_contains 'OnCalendar=*-*-*'
assert_contains 'IP_MODE="prefer6"'
assert_contains 'table inet setvps_family'
assert_contains 'set_default_route_source 4'
assert_contains 'set_default_route_source 6'
assert_contains 'show_public_ip_detection'
assert_contains 'https://api64.ipify.org'
assert_contains 'https://icanhazip.com'
assert_contains 'https://ifconfig.co/ip'
assert_contains '不直接判定 IPv6 不可用'

password_body="$(sed -n '/^generate_password()/,/^}/p' "${SCRIPT}")"
grep -Fq 'i < 14' <<<"${password_body}" || {
  printf 'password generator is not configured for 14 characters\n' >&2
  exit 1
}

printf 'static tests passed\n'
