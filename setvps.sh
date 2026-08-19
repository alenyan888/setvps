#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

VERSION="0.1.0"
INSTALL_PATH="/usr/local/sbin/setvps"
COMMAND_LINK="/usr/local/bin/setvps"
STATE_DIR="/etc/setvps"
BACKUP_DIR="${STATE_DIR}/backups"
REBOOT_HOURS_FILE="${STATE_DIR}/reboot-hours"
IP_CONFIG_FILE="${STATE_DIR}/ip.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-setvps.conf"
APT_UPDATED=0

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
  C_RESET=""
fi

log() { printf '%s\n' "${C_BLUE}[setvps]${C_RESET} $*"; }
ok() { printf '%s\n' "${C_GREEN}[成功]${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}[注意]${C_RESET} $*" >&2; }
die() { printf '%s\n' "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }

on_error() {
  local line="$1"
  local code="$2"
  printf '%s\n' "${C_RED}[错误]${C_RESET} 第 ${line} 行执行失败，退出码 ${code}。" >&2
}
trap 'on_error "$LINENO" "$?"' ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 运行：sudo setvps"
}

check_supported_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统，仅支持 Ubuntu/Debian。"
  # shellcheck disable=SC1091
  source /etc/os-release
  local family="${ID:-} ${ID_LIKE:-}"
  [[ "${family}" == *ubuntu* || "${family}" == *debian* ]] || \
    die "当前系统 ${PRETTY_NAME:-unknown} 不在支持范围内，仅支持 Ubuntu/Debian。"
}

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按 Enter 返回菜单..." _
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}

ensure_package() {
  local command_name="$1"
  local package_name="$2"
  command -v "${command_name}" >/dev/null 2>&1 && return 0
  if (( APT_UPDATED == 0 )); then
    log "更新 APT 软件索引..."
    apt-get update
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${package_name}"
  command -v "${command_name}" >/dev/null 2>&1 || die "安装 ${package_name} 后仍找不到 ${command_name}。"
}

install_self() {
  install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
  local current
  current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ "${current}" != "${INSTALL_PATH}" ]]; then
    install -m 0755 "$0" "${INSTALL_PATH}"
  else
    chmod 0755 "${INSTALL_PATH}"
  fi
  ln -sfn "${INSTALL_PATH}" "${COMMAND_LINK}"
  ok "已安装命令：${COMMAND_LINK}"
}

secure_random_number() {
  local max="$1"
  local value limit
  (( max > 0 && max <= 256 )) || return 1
  limit=$((256 - (256 % max)))
  while true; do
    value="$(od -An -N1 -tu1 /dev/urandom)"
    value="${value//[[:space:]]/}"
    [[ -n "${value}" ]] || continue
    if (( value < limit )); then
      printf '%d\n' "$((value % max))"
      return 0
    fi
  done
}

random_char() {
  local chars="$1"
  local index
  index="$(secure_random_number "${#chars}")"
  printf '%s' "${chars:index:1}"
}

generate_password() {
  local upper='ABCDEFGHJKLMNPQRSTUVWXYZ'
  local lower='abcdefghijkmnopqrstuvwxyz'
  local digit='23456789'
  local all="${upper}${lower}${digit}"
  local -a chars=()
  local i j tmp

  chars+=("$(random_char "${upper}")")
  chars+=("$(random_char "${lower}")")
  chars+=("$(random_char "${digit}")")
  for ((i = 3; i < 14; i++)); do
    chars+=("$(random_char "${all}")")
  done
  for ((i = 13; i > 0; i--)); do
    j="$(secure_random_number "$((i + 1))")"
    tmp="${chars[i]}"
    chars[i]="${chars[j]}"
    chars[j]="${tmp}"
  done
  printf '%s' "${chars[*]}" | tr -d ' '
}

reload_ssh_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
      systemctl enable --now ssh.service
      systemctl reload ssh.service
      return
    fi
    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
      systemctl enable --now sshd.service
      systemctl reload sshd.service
      return
    fi
  fi
  service ssh reload
}

enable_root_password_ssh() {
  ensure_package sshd openssh-server
  install -d -m 0755 /etc/ssh/sshd_config.d
  install -d -m 0700 "${BACKUP_DIR}"

  local stamp main_backup dropin_backup had_dropin=0 sshd_bin effective password
  stamp="$(date +%Y%m%d-%H%M%S)"
  main_backup="${BACKUP_DIR}/sshd_config.${stamp}"
  dropin_backup="${BACKUP_DIR}/00-setvps.conf.${stamp}"
  cp -a "${SSHD_CONFIG}" "${main_backup}"
  if [[ -e "${SSHD_DROPIN}" ]]; then
    cp -a "${SSHD_DROPIN}" "${dropin_backup}"
    had_dropin=1
  fi

  local temp_main temp_dropin
  temp_main="$(mktemp)"
  temp_dropin="$(mktemp)"
  {
    printf '%s\n' '# setvps keeps its early drop-in authoritative.'
    printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
    awk '!/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf([[:space:]]|$)/' "${SSHD_CONFIG}"
  } >"${temp_main}"
  cat >"${temp_dropin}" <<'EOF'
# Managed by setvps. Run `setvps` to change this configuration.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
UsePAM yes
EOF
  install -m 0644 "${temp_main}" "${SSHD_CONFIG}"
  install -m 0644 "${temp_dropin}" "${SSHD_DROPIN}"
  rm -f "${temp_main}" "${temp_dropin}"

  sshd_bin="$(command -v sshd)"
  if ! "${sshd_bin}" -t -f "${SSHD_CONFIG}"; then
    cp -a "${main_backup}" "${SSHD_CONFIG}"
    if (( had_dropin == 1 )); then
      cp -a "${dropin_backup}" "${SSHD_DROPIN}"
    else
      rm -f "${SSHD_DROPIN}"
    fi
    die "SSH 配置校验失败，已自动恢复原配置。"
  fi

  effective="$("${sshd_bin}" -T -f "${SSHD_CONFIG}" -C "user=root,host=$(hostname),addr=127.0.0.1")"
  grep -qx 'passwordauthentication yes' <<<"${effective}" || die "PasswordAuthentication 未生效。"
  grep -qx 'permitrootlogin yes' <<<"${effective}" || die "PermitRootLogin 未生效。"

  reload_ssh_service
  password="$(generate_password)"
  printf 'root:%s\n' "${password}" | chpasswd

  printf '\n%s\n' "${C_BOLD}${C_GREEN}Root SSH 密码登录已开启${C_RESET}"
  printf '用户名：%s\n' 'root'
  printf '随机密码：%s%s%s\n' "${C_BOLD}" "${password}" "${C_RESET}"
  printf '长度：14 位（大小写字母和数字，排除易混淆字符）\n'
  printf '配置备份：%s\n\n' "${main_backup}"
  warn "密码仅显示这一次，请立即保存。建议限制 SSH 来源 IP，并避免在公网长期开放密码登录。"
}

configure_swap() {
  local size_gib="$1"
  [[ "${size_gib}" == "2" || "${size_gib}" == "4" ]] || die "Swap 仅支持 2G 或 4G。"
  ensure_package mkswap util-linux
  install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"

  if [[ -e /swapfile && ! -f "${STATE_DIR}/swap.conf" ]]; then
    warn "/swapfile 已存在，但不是 setvps 创建的文件。"
    confirm "确认替换它吗？" || return 0
  fi

  local fstab_backup
  fstab_backup="${BACKUP_DIR}/fstab.$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/fstab "${fstab_backup}"

  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq '/swapfile'; then
    swapoff /swapfile
  fi
  rm -f /swapfile
  truncate -s 0 /swapfile
  if findmnt -no FSTYPE / 2>/dev/null | grep -qx 'btrfs'; then
    chattr +C /swapfile 2>/dev/null || true
    if command -v btrfs >/dev/null 2>&1; then
      btrfs property set /swapfile compression none 2>/dev/null || true
    fi
  fi
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "${size_gib}G" /swapfile; then
    :
  else
    dd if=/dev/zero of=/swapfile bs=1M count="$((size_gib * 1024))" status=progress
  fi
  chmod 0600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile

  local temp_fstab
  temp_fstab="$(mktemp)"
  awk '$1 != "/swapfile"' /etc/fstab >"${temp_fstab}"
  printf '%s\n' '/swapfile none swap sw 0 0' >>"${temp_fstab}"
  install -m 0644 "${temp_fstab}" /etc/fstab
  rm -f "${temp_fstab}"
  printf 'SIZE_GIB=%q\n' "${size_gib}" >"${STATE_DIR}/swap.conf"

  swapon --noheadings --show=NAME | grep -Fxq '/swapfile' || die "Swap 启用验证失败。"
  awk '$1 == "/swapfile" && $3 == "swap" {found=1} END {exit !found}' /etc/fstab || \
    die "Swap 持久化验证失败。"
  ok "${size_gib}G Swap 已启用并写入 /etc/fstab，重启后仍生效。"
  free -h
}

swap_menu() {
  printf '\n%s\n' "${C_BOLD}选择 Swap 大小${C_RESET}"
  printf '  1) 2G（默认）\n'
  printf '  2) 4G\n'
  printf '  0) 返回\n'
  local choice
  read -r -p '请选择 [1]: ' choice
  choice="${choice:-1}"
  case "${choice}" in
    1) configure_swap 2 ;;
    2) configure_swap 4 ;;
    0) return ;;
    *) warn "无效选项。" ;;
  esac
}

write_reboot_service() {
  cat >/etc/systemd/system/setvps-reboot.service <<'EOF'
[Unit]
Description=Scheduled reboot managed by setvps

[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -r now
EOF
}

valid_hour() {
  [[ "$1" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3])$ ]]
}

normalize_hour() {
  printf '%02d\n' "$((10#$1))"
}

show_hour_grid() {
  local h
  printf '\n可选时间（使用服务器本机时区）：\n'
  for ((h = 0; h < 24; h++)); do
    printf '%02d点  ' "${h}"
    if (((h + 1) % 6 == 0)); then
      printf '\n'
    fi
  done
}

rebuild_reboot_timer() {
  install -d -m 0700 "${STATE_DIR}"
  write_reboot_service
  local -a hours=()
  if [[ -f "${REBOOT_HOURS_FILE}" ]]; then
    mapfile -t hours < <(grep -E '^(0[0-9]|1[0-9]|2[0-3])$' "${REBOOT_HOURS_FILE}" | sort -n -u)
  fi
  if ((${#hours[@]} == 0)); then
    systemctl disable --now setvps-reboot.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/setvps-reboot.timer
    systemctl daemon-reload
    ok "当前没有每日重启任务。"
    return
  fi

  {
    printf '%s\n' '[Unit]'
    printf '%s\n\n' 'Description=Daily reboot schedule managed by setvps'
    printf '%s\n' '[Timer]'
    local hour
    for hour in "${hours[@]}"; do
      printf 'OnCalendar=*-*-* %s:00:00\n' "${hour}"
    done
    printf '%s\n' 'AccuracySec=1min'
    printf '%s\n' 'RandomizedDelaySec=0'
    printf '%s\n' 'Unit=setvps-reboot.service'
    printf '%s\n\n' '[Install]'
    printf '%s\n' 'WantedBy=timers.target'
  } >/etc/systemd/system/setvps-reboot.timer
  chmod 0644 /etc/systemd/system/setvps-reboot.timer /etc/systemd/system/setvps-reboot.service
  systemctl daemon-reload
  systemctl enable --now setvps-reboot.timer >/dev/null
  systemctl is-active --quiet setvps-reboot.timer || die "定时重启任务启动失败。"
  ok "每日重启时间已设置：${hours[*]} 点（本机时区）"
  systemctl list-timers setvps-reboot.timer --all --no-pager || true
}

add_reboot_hours() {
  show_hour_grid
  local input token normalized
  read -r -p '输入一个或多个小时，例如 0,6,23：' input
  input="${input//,/ }"
  local temp
  temp="$(mktemp)"
  [[ -f "${REBOOT_HOURS_FILE}" ]] && cp "${REBOOT_HOURS_FILE}" "${temp}"
  for token in ${input}; do
    if ! valid_hour "${token}"; then
      rm -f "${temp}"
      warn "无效小时：${token}，请输入 0-23。"
      return
    fi
    normalized="$(normalize_hour "${token}")"
    printf '%s\n' "${normalized}" >>"${temp}"
  done
  sort -n -u "${temp}" >"${REBOOT_HOURS_FILE}"
  chmod 0600 "${REBOOT_HOURS_FILE}"
  rm -f "${temp}"
  rebuild_reboot_timer
}

delete_reboot_hours() {
  if [[ ! -s "${REBOOT_HOURS_FILE}" ]]; then
    warn "当前没有可删除的重启时间。"
    return
  fi
  local -a current=()
  mapfile -t current < <(sort -n -u "${REBOOT_HOURS_FILE}")
  printf '当前重启时间：%s 点\n' "${current[*]}"
  local input token normalized
  read -r -p '输入要删除的一个或多个小时，例如 6,23；输入 all 删除全部：' input
  if [[ "${input,,}" == "all" ]]; then
    : >"${REBOOT_HOURS_FILE}"
    rebuild_reboot_timer
    return
  fi
  input="${input//,/ }"
  local temp remove_file
  temp="$(mktemp)"
  remove_file="$(mktemp)"
  for token in ${input}; do
    if ! valid_hour "${token}"; then
      rm -f "${temp}" "${remove_file}"
      warn "无效小时：${token}。"
      return
    fi
    normalize_hour "${token}" >>"${remove_file}"
  done
  grep -Fvx -f "${remove_file}" "${REBOOT_HOURS_FILE}" >"${temp}" || true
  install -m 0600 "${temp}" "${REBOOT_HOURS_FILE}"
  rm -f "${temp}" "${remove_file}"
  rebuild_reboot_timer
}

show_reboot_schedule() {
  local timezone
  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  printf '本机时间：%s\n' "$(date '+%F %T %Z')"
  printf '本机时区：%s\n' "${timezone:-未知}"
  if [[ -s "${REBOOT_HOURS_FILE}" ]]; then
    printf '每日重启：%s 点\n' "$(sort -n -u "${REBOOT_HOURS_FILE}" | tr '\n' ' ')"
  else
    printf '每日重启：未设置\n'
  fi
  systemctl list-timers setvps-reboot.timer --all --no-pager 2>/dev/null || true
}

reboot_menu() {
  while true; do
    printf '\n%s\n' "${C_BOLD}每日定时重启${C_RESET}"
    show_reboot_schedule
    printf '\n  1) 添加重启时间\n'
    printf '  2) 删除重启时间\n'
    printf '  3) 查看任务状态\n'
    printf '  0) 返回\n'
    local choice
    read -r -p '请选择：' choice
    case "${choice}" in
      1) add_reboot_hours ;;
      2) delete_reboot_hours ;;
      3) show_reboot_schedule ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

remove_gai_block() {
  local file=/etc/gai.conf
  [[ -e "${file}" ]] || touch "${file}"
  local temp
  temp="$(mktemp)"
  awk '
    /^# BEGIN SETVPS ADDRESS POLICY$/ {skip=1; next}
    /^# END SETVPS ADDRESS POLICY$/ {skip=0; next}
    !skip {print}
  ' "${file}" >"${temp}"
  install -m 0644 "${temp}" "${file}"
  rm -f "${temp}"
}

apply_gai_policy() {
  local mode="$1"
  remove_gai_block
  local v6_precedence=100 v4_precedence=10
  if [[ "${mode}" == "ipv4_only" || "${mode}" == "prefer4" ]]; then
    v6_precedence=40
    v4_precedence=100
  fi
  cat >>/etc/gai.conf <<EOF

# BEGIN SETVPS ADDRESS POLICY
# Full precedence table: adding one precedence rule replaces libc defaults.
precedence ::1/128       50
precedence ::/0          ${v6_precedence}
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 ${v4_precedence}
# END SETVPS ADDRESS POLICY
EOF
}

clear_nft_policy() {
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet setvps_family >/dev/null 2>&1 || true
  fi
}

apply_strict_family_policy() {
  local mode="$1"
  clear_nft_policy
  [[ "${mode}" == "ipv4_only" || "${mode}" == "ipv6_only" ]] || return 0
  command -v nft >/dev/null 2>&1 || die "严格 IP 模式需要 nftables，请重新进入 setvps 设置。"
  if [[ "${mode}" == "ipv4_only" ]]; then
    nft -f - <<'EOF'
table inet setvps_family {
  chain output {
    type filter hook output priority -10; policy accept;
    oifname "lo" accept
    ct state established,related accept
    ip6 daddr { ::1/128, fe80::/10, ff00::/8 } accept
    meta nfproto ipv6 ct state new reject with icmpv6 type admin-prohibited
  }
}
EOF
  else
    nft -f - <<'EOF'
table inet setvps_family {
  chain output {
    type filter hook output priority -10; policy accept;
    oifname "lo" accept
    ct state established,related accept
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } accept
    meta nfproto ipv4 ct state new reject with icmp type admin-prohibited
  }
}
EOF
  fi
}

address_is_local_global() {
  local family="$1"
  local address="$2"
  ip -o -"${family}" addr show scope global | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "${address}"
}

set_default_route_source() {
  local family="$1"
  local source="$2"
  [[ -n "${source}" ]] || return 0
  address_is_local_global "${family}" "${source}" || die "配置的 IPv${family} 源地址已不在本机：${source}"
  local route
  route="$(ip -"${family}" route show default | head -n1)"
  [[ -n "${route}" ]] || die "找不到 IPv${family} 默认路由，无法固定源地址。"
  local -a tokens=() cleaned=()
  local skip=0 token
  read -r -a tokens <<<"${route}"
  for token in "${tokens[@]}"; do
    if (( skip == 1 )); then
      skip=0
      continue
    fi
    if [[ "${token}" == "src" ]]; then
      skip=1
      continue
    fi
    cleaned+=("${token}")
  done
  cleaned+=(src "${source}")
  ip -"${family}" route replace "${cleaned[@]}"

  local test_target result
  if [[ "${family}" == "4" ]]; then
    test_target="1.1.1.1"
  else
    test_target="2606:4700:4700::1111"
  fi
  result="$(ip -"${family}" route get "${test_target}")"
  grep -Fq "src ${source}" <<<"${result}" || die "IPv${family} 源地址路由验证失败：${result}"
}

load_ip_config() {
  IP_MODE="prefer6"
  IPV4_SOURCE=""
  IPV6_SOURCE=""
  if [[ -r "${IP_CONFIG_FILE}" ]]; then
    # This root-owned file is written using shell escaping by setvps.
    # shellcheck disable=SC1090
    source "${IP_CONFIG_FILE}"
  fi
}

apply_ip_policy() {
  require_root
  load_ip_config
  case "${IP_MODE}" in
    ipv4_only|ipv6_only|prefer4|prefer6) ;;
    *) die "未知 IP 模式：${IP_MODE}" ;;
  esac
  apply_gai_policy "${IP_MODE}"
  apply_strict_family_policy "${IP_MODE}"
  set_default_route_source 4 "${IPV4_SOURCE}"
  set_default_route_source 6 "${IPV6_SOURCE}"
  log "IP 策略已应用：${IP_MODE}"
}

clear_ip_policy() {
  require_root
  clear_nft_policy
}

write_ip_service() {
  cat >/etc/systemd/system/setvps-ip.service <<EOF
[Unit]
Description=Outbound IP policy managed by setvps
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --apply-ip-policy
ExecStop=${INSTALL_PATH} --clear-ip-policy
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/setvps-ip.service
}

mode_label() {
  case "$1" in
    ipv4_only) printf '仅公网 IPv4（严格）' ;;
    ipv6_only) printf '仅公网 IPv6（严格）' ;;
    prefer4) printf 'IPv4 优先，失败后 IPv6' ;;
    prefer6) printf 'IPv6 优先，失败后 IPv4' ;;
    *) printf '未知' ;;
  esac
}

show_detected_ips() {
  printf '\n%s\n' "${C_BOLD}网卡全局地址${C_RESET}"
  ip -o -4 addr show scope global | awk '{print "IPv4  " $2 "  " $4}' || true
  ip -o -6 addr show scope global | awk '{print "IPv6  " $2 "  " $4}' || true
  printf '\n%s\n' "${C_BOLD}当前默认路由选择${C_RESET}"
  ip -4 route get 1.1.1.1 2>/dev/null || printf 'IPv4：不可用\n'
  ip -6 route get 2606:4700:4700::1111 2>/dev/null || printf 'IPv6：不可用\n'
  if command -v curl >/dev/null 2>&1; then
    local public4 public6
    public4="$(curl -4fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    public6="$(curl -6fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    printf '\n公网检测：IPv4=%s  IPv6=%s\n' "${public4:-不可用}" "${public6:-不可用}"
  fi
}

choose_source_address() {
  local family="$1"
  local current_source="$2"
  local -a addresses=()
  mapfile -t addresses < <(ip -o -"${family}" addr show scope global | awk '{split($4,a,"/"); print a[1]}' | sort -u)
  SELECTED_SOURCE="${current_source}"
  if ((${#addresses[@]} == 0)); then
    printf '本机没有全局 IPv%s 地址，跳过源地址设置。\n' "${family}"
    SELECTED_SOURCE=""
    return
  fi
  printf '\n选择固定的 IPv%s 出站源地址：\n' "${family}"
  local i
  for i in "${!addresses[@]}"; do
    printf '  %d) %s' "$((i + 1))" "${addresses[i]}"
    [[ "${addresses[i]}" == "${current_source}" ]] && printf '（当前）'
    printf '\n'
  done
  printf '  c) 清除固定源地址，由内核自动选择\n'
  printf '  0) 保持当前设置\n'
  local choice
  read -r -p '请选择：' choice
  case "${choice}" in
    0|'') return ;;
    c|C) SELECTED_SOURCE=""; return ;;
  esac
  [[ "${choice}" =~ ^[0-9]+$ ]] || { warn "无效选项，保持当前设置。"; return; }
  (( choice >= 1 && choice <= ${#addresses[@]} )) || { warn "无效选项，保持当前设置。"; return; }
  SELECTED_SOURCE="${addresses[choice - 1]}"
}

configure_ip_policy() {
  load_ip_config
  show_detected_ips
  printf '\n%s\n' "${C_BOLD}选择出站协议策略${C_RESET}"
  printf '  1) 仅公网 IPv4（严格阻止新建公网 IPv6 连接）\n'
  printf '  2) 仅公网 IPv6（严格阻止新建公网 IPv4 连接）\n'
  printf '  3) IPv4 优先，失败后 IPv6\n'
  printf '  4) IPv6 优先，失败后 IPv4\n'
  printf '  0) 返回\n'
  printf '当前策略：%s\n' "$(mode_label "${IP_MODE}")"
  local choice new_mode
  read -r -p '请选择：' choice
  case "${choice}" in
    1) new_mode="ipv4_only" ;;
    2) new_mode="ipv6_only" ;;
    3) new_mode="prefer4" ;;
    4) new_mode="prefer6" ;;
    0|'') return ;;
    *) warn "无效选项。"; return ;;
  esac

  if [[ "${new_mode}" == "ipv4_only" || "${new_mode}" == "ipv6_only" ]]; then
    warn "严格模式会阻止另一协议族的新建公网连接；已建立连接、回环、私网和云元数据网段不受影响。"
    confirm "确认启用 $(mode_label "${new_mode}")？" || return
    ensure_package nft nftables
  fi

  choose_source_address 4 "${IPV4_SOURCE}"
  local new_v4="${SELECTED_SOURCE}"
  choose_source_address 6 "${IPV6_SOURCE}"
  local new_v6="${SELECTED_SOURCE}"

  install -d -m 0700 "${STATE_DIR}"
  {
    printf 'IP_MODE=%q\n' "${new_mode}"
    printf 'IPV4_SOURCE=%q\n' "${new_v4}"
    printf 'IPV6_SOURCE=%q\n' "${new_v6}"
  } >"${IP_CONFIG_FILE}"
  chmod 0600 "${IP_CONFIG_FILE}"
  write_ip_service
  systemctl daemon-reload
  systemctl enable setvps-ip.service >/dev/null
  systemctl restart setvps-ip.service
  systemctl is-active --quiet setvps-ip.service || die "IP 策略服务未成功启动。"

  ok "已设置：$(mode_label "${new_mode}")"
  [[ -n "${new_v4}" ]] && printf '固定 IPv4 源地址：%s\n' "${new_v4}"
  [[ -n "${new_v6}" ]] && printf '固定 IPv6 源地址：%s\n' "${new_v6}"
  show_detected_ips
  warn "glibc 地址优先级对多数程序生效；明确指定 -4/-6、自带 DNS 或代理网络栈的程序可能不遵循该优先级。"
}

show_status() {
  printf '\n%s setvps v%s%s\n' "${C_BOLD}" "${VERSION}" "${C_RESET}"
  printf '系统：'
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-未知}"
  else
    printf '未知\n'
  fi
  printf '本机时间：%s\n' "$(date '+%F %T %Z')"

  printf '\nSSH：'
  if command -v sshd >/dev/null 2>&1; then
    local ssh_status
    ssh_status="$(sshd -T -C "user=root,host=$(hostname),addr=127.0.0.1" 2>/dev/null | awk '/^(passwordauthentication|permitrootlogin) / {printf "%s=%s ",$1,$2}')"
    printf '%s\n' "${ssh_status:-无法读取}"
  else
    printf '未安装\n'
  fi

  printf 'Swap：\n'
  swapon --show 2>/dev/null || true
  printf '\n重启任务：\n'
  show_reboot_schedule

  load_ip_config
  printf '\nIP 策略：%s\n' "$(mode_label "${IP_MODE}")"
  printf '固定 IPv4 源地址：%s\n' "${IPV4_SOURCE:-自动}"
  printf '固定 IPv6 源地址：%s\n' "${IPV6_SOURCE:-自动}"
  show_detected_ips
}

main_menu() {
  while true; do
    printf '\n%s\n' "${C_BOLD}========== setvps v${VERSION} ==========${C_RESET}"
    printf '  1) 开启 Root SSH 密码登录并生成 14 位密码\n'
    printf '  2) 配置 2G/4G Swap\n'
    printf '  3) 管理每日定时重启\n'
    printf '  4) 检测 IP、设置协议优先级和出站源 IP\n'
    printf '  5) 查看当前状态\n'
    printf '  0) 退出\n'
    local choice
    read -r -p '请选择：' choice
    case "${choice}" in
      1) enable_root_password_ssh; pause ;;
      2) swap_menu; pause ;;
      3) reboot_menu ;;
      4) configure_ip_policy; pause ;;
      5) show_status; pause ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

usage() {
  cat <<EOF
setvps v${VERSION}

用法：
  setvps                 打开交互式菜单
  setvps ssh             设置 Root SSH 密码登录
  setvps swap 2|4        创建 2G 或 4G Swap
  setvps reboot          管理每日重启时间
  setvps ip              管理 IP 出站策略
  setvps status          查看状态
  setvps --install       安装/更新 setvps 命令
EOF
}

require_root
check_supported_os

case "${1:-}" in
  --apply-ip-policy) apply_ip_policy; exit 0 ;;
  --clear-ip-policy) clear_ip_policy; exit 0 ;;
esac

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/setvps.lock
  flock -n 9 || die "另一个 setvps 进程正在运行。"
fi

case "${1:-}" in
  --install)
    install_self
    exit 0
    ;;
  ssh)
    install_self
    enable_root_password_ssh
    ;;
  swap)
    install_self
    [[ -n "${2:-}" ]] || die "请指定 2 或 4，例如：setvps swap 2"
    configure_swap "$2"
    ;;
  reboot)
    install_self
    reboot_menu
    ;;
  ip)
    install_self
    configure_ip_policy
    ;;
  status)
    show_status
    ;;
  -h|--help)
    usage
    ;;
  '')
    install_self
    main_menu
    ;;
  *)
    usage
    exit 1
    ;;
esac
