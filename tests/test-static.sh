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
assert_contains 'BBR_SYSCTL_FILE="/etc/sysctl.d/99-zz-setvps-bbr.conf"'
assert_contains 'net.core.default_qdisc = fq'
assert_contains 'net.ipv4.tcp_congestion_control = %s'
assert_contains 'BBR_MODULE_SYSFS_DIR="/sys/module/tcp_bbr"'
# shellcheck disable=SC2016
assert_contains '"${BBR_MODULE_SYSFS_DIR}/version"'
assert_contains 'modinfo -F version tcp_bbr'
assert_contains 'load_bbr_candidate'
# shellcheck disable=SC2016
assert_contains 'modprobe "${tcp_module}"'
assert_contains 'bbr_algorithm_available bbr2'
assert_contains 'recommend_bbr_algorithm'
assert_contains 'verify_bbr_runtime'
assert_contains 'rollback_bbr_enable'
assert_contains 'PREVIOUS_CC='
assert_contains 'PREVIOUS_QDISC='
assert_contains 'setvps bbr auto|v3|v2|native|status|off'
assert_contains 'setvps 不会自动下载、编译或替换 AWS/GCP 的内核'

assert_not_contains() {
  local text="$1"
  if grep -Fq "${text}" "${SCRIPT}"; then
    printf 'unsafe BBR contract found: %s\n' "${text}" >&2
    exit 1
  fi
}

assert_not_contains 'sysctl --system'
assert_not_contains 'modprobe -r'
assert_not_contains 'tc qdisc replace'
assert_not_contains 'apt-get install -y linux-image'
assert_not_contains 'for module in sch_fq tcp_bbr3 tcp_bbr tcp_bbr2'

recommendation_body="$(sed -n '/^recommend_bbr_algorithm()/,/^}/p' "${SCRIPT}")"
v3_line="$(grep -nF 'bbr_algorithm_available bbr3' <<<"${recommendation_body}" | head -n1 | cut -d: -f1)"
v2_line="$(grep -nF 'bbr_algorithm_available bbr2' <<<"${recommendation_body}" | head -n1 | cut -d: -f1)"
native_line="$(grep -nF 'BBR_RECOMMENDED_ALGORITHM="bbr"' <<<"${recommendation_body}" | tail -n1 | cut -d: -f1)"
[[ -n "${v3_line}" && -n "${v2_line}" && -n "${native_line}" ]] || {
  printf 'BBR recommendation order cannot be inspected\n' >&2
  exit 1
}
(( v3_line < v2_line && v2_line < native_line )) || {
  printf 'BBR recommendation must prefer verified v3, then v2, then native bbr\n' >&2
  exit 1
}

enable_bbr_body="$(sed -n '/^enable_bbr()/,/^}/p' "${SCRIPT}")"
grep -Fq 'save_bbr_previous_state_once' <<<"${enable_bbr_body}" || exit 1
grep -Fq 'verify_bbr_runtime' <<<"${enable_bbr_body}" || exit 1

disable_bbr_body="$(sed -n '/^disable_bbr()/,/^}/p' "${SCRIPT}")"
grep -Fq 'read_bbr_state_value PREVIOUS_CC' <<<"${disable_bbr_body}" || exit 1
grep -Fq 'remove_bbr_managed_file' <<<"${disable_bbr_body}" || exit 1

password_body="$(sed -n '/^generate_password()/,/^}/p' "${SCRIPT}")"
grep -Fq 'i < 14' <<<"${password_body}" || {
  printf 'password generator is not configured for 14 characters\n' >&2
  exit 1
}

printf 'static tests passed\n'
