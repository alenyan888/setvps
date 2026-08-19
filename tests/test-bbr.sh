#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setvps.sh
source "${ROOT_DIR}/setvps.sh"

TEST_ROOT="$(mktemp -d)"
MOCK_BIN="${TEST_ROOT}/bin"
mkdir -p "${MOCK_BIN}"

cleanup() {
  unset MOCK_FAIL_RM_TARGET MOCK_FAIL_INSTALL_TARGET
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

export MOCK_CC_FILE="${TEST_ROOT}/current-cc"
export MOCK_QDISC_FILE="${TEST_ROOT}/current-qdisc"
export MOCK_AVAILABLE_FILE="${TEST_ROOT}/available-cc"
export MOCK_SYSCTL_LOG="${TEST_ROOT}/sysctl.log"
export MOCK_MODPROBE_LOG="${TEST_ROOT}/modprobe.log"

cat >"${MOCK_BIN}/sysctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${MOCK_SYSCTL_LOG}"
if [[ "${1:-}" == "-n" ]]; then
  case "${2:-}" in
    net.ipv4.tcp_congestion_control) cat "${MOCK_CC_FILE}" ;;
    net.core.default_qdisc) cat "${MOCK_QDISC_FILE}" ;;
    net.ipv4.tcp_available_congestion_control) cat "${MOCK_AVAILABLE_FILE}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "-q" && "${2:-}" == "-w" ]]; then
  assignment="${3:-}"
elif [[ "${1:-}" == "-w" ]]; then
  assignment="${2:-}"
else
  exit 1
fi
key="${assignment%%=*}"
value="${assignment#*=}"
case "${key}" in
  net.ipv4.tcp_congestion_control) printf '%s\n' "${value}" >"${MOCK_CC_FILE}" ;;
  net.core.default_qdisc) printf '%s\n' "${value}" >"${MOCK_QDISC_FILE}" ;;
  *) exit 1 ;;
esac
EOF

cat >"${MOCK_BIN}/modprobe" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${MOCK_MODPROBE_LOG}"
EOF

cat >"${MOCK_BIN}/modinfo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"${MOCK_BIN}/install" <<'EOF'
#!/usr/bin/env bash
set -eu
last="${!#}"
if [[ -n "${MOCK_FAIL_INSTALL_TARGET:-}" && "${last}" == "${MOCK_FAIL_INSTALL_TARGET}" ]]; then
  exit 1
fi
exec /usr/bin/install "$@"
EOF

cat >"${MOCK_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
set -eu
for argument in "$@"; do
  if [[ -n "${MOCK_FAIL_RM_TARGET:-}" && "${argument}" == "${MOCK_FAIL_RM_TARGET}" ]]; then
    exit 1
  fi
done
exec /usr/bin/rm "$@"
EOF

chmod +x "${MOCK_BIN}/sysctl" "${MOCK_BIN}/modprobe" "${MOCK_BIN}/modinfo" \
  "${MOCK_BIN}/install" "${MOCK_BIN}/rm"
export PATH="${MOCK_BIN}:${PATH}"

STATE_DIR="${TEST_ROOT}/state"
BBR_STATE_FILE="${STATE_DIR}/bbr.conf"
BBR_SYSCTL_FILE="${TEST_ROOT}/sysctl.d/99-zz-setvps-bbr.conf"
BBR_MODULES_FILE="${TEST_ROOT}/modules-load.d/setvps-bbr.conf"
BBR_MODULE_SYSFS_DIR="${TEST_ROOT}/sys-module/tcp_bbr"
mkdir -p "${STATE_DIR}" "$(dirname "${BBR_SYSCTL_FILE}")" \
  "$(dirname "${BBR_MODULES_FILE}")" "${BBR_MODULE_SYSFS_DIR}"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'assertion failed: %s (expected=%s actual=%s)\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

reset_runtime() {
  printf 'cubic\n' >"${MOCK_CC_FILE}"
  printf 'fq_codel\n' >"${MOCK_QDISC_FILE}"
  printf 'reno cubic bbr\n' >"${MOCK_AVAILABLE_FILE}"
  : >"${MOCK_SYSCTL_LOG}"
  : >"${MOCK_MODPROBE_LOG}"
  rm -f -- "${BBR_STATE_FILE}" "${BBR_SYSCTL_FILE}" "${BBR_MODULES_FILE}" \
    "${BBR_MODULE_SYSFS_DIR}/version"
}

reset_runtime
disable_bbr
[[ ! -s "${MOCK_SYSCTL_LOG}" ]] || {
  printf 'disable_bbr changed an unmanaged BBR setup\n' >&2
  exit 1
}

printf 'reno cubic bbr bbr2 bbr3\n' >"${MOCK_AVAILABLE_FILE}"
recommend_bbr_algorithm
assert_eq bbr3 "${BBR_RECOMMENDED_ALGORITHM}" 'registered BBRv3 must have highest priority'

printf '3\n' >"${BBR_MODULE_SYSFS_DIR}/version"
printf 'reno cubic bbr bbr2\n' >"${MOCK_AVAILABLE_FILE}"
recommend_bbr_algorithm
assert_eq bbr "${BBR_RECOMMENDED_ALGORITHM}" 'tcp_bbr module version 3 must beat BBRv2'

rm -f -- "${BBR_MODULE_SYSFS_DIR}/version"
recommend_bbr_algorithm
assert_eq bbr2 "${BBR_RECOMMENDED_ALGORITHM}" 'BBRv2 must beat unversioned bbr'

printf 'reno cubic bbr\n' >"${MOCK_AVAILABLE_FILE}"
recommend_bbr_algorithm
assert_eq bbr "${BBR_RECOMMENDED_ALGORITHM}" 'native bbr must be the safe fallback'

reset_runtime
export MOCK_FAIL_INSTALL_TARGET="${BBR_SYSCTL_FILE}"
if enable_bbr auto; then
  printf 'enable_bbr unexpectedly succeeded when persistence failed\n' >&2
  exit 1
fi
unset MOCK_FAIL_INSTALL_TARGET
assert_eq cubic "$(cat "${MOCK_CC_FILE}")" 'failed enable must restore congestion control'
assert_eq fq_codel "$(cat "${MOCK_QDISC_FILE}")" 'failed enable must restore qdisc'
[[ ! -e "${BBR_STATE_FILE}" && ! -e "${BBR_SYSCTL_FILE}" ]] || {
  printf 'failed enable left managed state behind\n' >&2
  exit 1
}

{
  printf '%s\n' "${BBR_MANAGED_MARKER}"
  printf 'STATE_VERSION=1\n'
  printf 'PREVIOUS_CC=cubic\n'
  printf 'PREVIOUS_QDISC=fq_codel\n'
} >"${BBR_STATE_FILE}"
{
  printf '%s\n' "${BBR_MANAGED_MARKER}"
  printf 'net.core.default_qdisc = fq\n'
  printf 'net.ipv4.tcp_congestion_control = bbr\n'
} >"${BBR_SYSCTL_FILE}"
{
  printf '%s\n' "${BBR_MANAGED_MARKER}"
  printf 'tcp_bbr\n'
} >"${BBR_MODULES_FILE}"
printf 'bbr\n' >"${MOCK_CC_FILE}"
printf 'fq\n' >"${MOCK_QDISC_FILE}"
export MOCK_FAIL_RM_TARGET="${BBR_SYSCTL_FILE}"
if disable_bbr; then
  printf 'disable_bbr unexpectedly succeeded when persistence removal failed\n' >&2
  exit 1
fi
unset MOCK_FAIL_RM_TARGET
assert_eq bbr "$(cat "${MOCK_CC_FILE}")" 'failed disable must keep original congestion control'
assert_eq fq "$(cat "${MOCK_QDISC_FILE}")" 'failed disable must keep original qdisc'
[[ -e "${BBR_STATE_FILE}" && -e "${BBR_SYSCTL_FILE}" && -e "${BBR_MODULES_FILE}" ]] || {
  printf 'failed disable did not restore managed files\n' >&2
  exit 1
}

disable_bbr
assert_eq cubic "$(cat "${MOCK_CC_FILE}")" 'disable must restore previous congestion control'
assert_eq fq_codel "$(cat "${MOCK_QDISC_FILE}")" 'disable must restore previous qdisc'
[[ ! -e "${BBR_STATE_FILE}" && ! -e "${BBR_SYSCTL_FILE}" && ! -e "${BBR_MODULES_FILE}" ]] || {
  printf 'successful disable left managed files behind\n' >&2
  exit 1
}

printf 'BBR behavior tests passed\n'
