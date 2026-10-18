#!/usr/bin/env bash
#
# nw.sh — Nowhere (NW3) one-click installer & service manager
#         Nowhere (NW3) 一键安装与服务管理脚本
#
# Upstream protocol : https://github.com/NodePassProject/Nowhere
# This repository   : https://github.com/elysianki4225-png/Nowhere
# License           : GNU General Public License v3.0 or later
#
# ---------------------------------------------------------------------------
# Nowhere relays TCP and UDP traffic over TLS and QUIC with three roles:
#
#     +----------+  TLS/QUIC  +----------+  direct / SOCKS5  +----------+
#     |  Vector  |----------->|  Portal  |------------------>|  Target  |
#     +----------+            +----------+                   +----------+
#                                 ^
#                                 | QUIC
#                           +----------+      TCP / UDP     +----------+
#                           |  Egress  |------------------>|  Target  |
#                           +----------+                   +----------+
#
# This script installs the official `nowhere` binary from GitHub releases,
# generates a systemd service per instance and manages the full lifecycle.
# 本脚本从 GitHub Releases 安装官方 nowhere 二进制，为每个实例生成 systemd
# 服务并管理完整生命周期。
#
# Usage / 用法:
#   bash nw.sh                          interactive wizard / 交互式向导
#   bash nw.sh portal|vector|egress     quick role install / 指定角色安装
#   bash nw.sh menu                     management menu / 管理菜单
#   bash nw.sh help                     full reference / 完整帮助
# ---------------------------------------------------------------------------
set -euo pipefail

# ============================== metadata ====================================
NW_VERSION="1.0.0"
REPO_SLUG="${NW_REPO_SLUG:-elysianki4225-png/Nowhere}"
REPO_REF="${NW_REF:-main}"
REPO_RAW_BASE="${NW_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}}"
UPSTREAM_SLUG="${NW_UPSTREAM:-NodePassProject/Nowhere}"
UPSTREAM_API="${NW_UPSTREAM_API:-https://api.github.com/repos/${UPSTREAM_SLUG}}"
PREFIX="${NW_PREFIX:-/usr/local}"
BIN_DIR="${PREFIX}/bin"
NOWHERE_BIN="${BIN_DIR}/nowhere"
NW_BIN="${BIN_DIR}/nw"
ETC_DIR="${NW_ETC:-/etc/nowhere}"
LANG_FILE="${ETC_DIR}/.lang"
CURL_UA="nw.sh/${NW_VERSION} (+https://github.com/${REPO_SLUG})"

# ============================== colors ======================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# ============================== language ====================================
resolve_lang() {
  local l="${NW_LANG:-}"
  if [ -z "$l" ] && [ -f "$LANG_FILE" ]; then
    l="$(head -n1 "$LANG_FILE" 2>/dev/null || true)"
  fi
  if [ -z "$l" ]; then
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
      zh*|ZH*) l=zh ;;
      *) l=en ;;
    esac
  fi
  case "$l" in
    zh|zh_CN|zh-CN|zh_TW|zh-TW|ZH|Chinese|chinese) NW_LANG_CODE=zh ;;
    *) NW_LANG_CODE=en ;;
  esac
}

# t <id> [args...] — print a localized message. Args feed printf %s slots.
t() {
  local id="$1"; shift
  local zh="" en="" out
  case "$id" in
    banner)
      zh=$'Nowhere (NW3) 一键安装与管理脚本\n安全传输 · 灵活出口 — TCP/UDP over TLS & QUIC'
      en=$'Nowhere (NW3) one-click installer & manager\nSecure transport, flexible exits — TCP/UDP over TLS & QUIC' ;;
    need_root)        zh="请以 root 运行（或使用 sudo）。"; en="Please run as root (or via sudo)." ;;
    sudo_missing)     zh="未找到 sudo，请切换到 root 用户后重试。"; en="sudo not found; switch to root and retry." ;;
    platform)         zh="平台检测：%s → 发行资产 %s"; en="Platform: %s → release asset %s" ;;
    err_os)           zh="不支持的操作系统：%s"; en="Unsupported operating system: %s" ;;
    err_arch)         zh="不支持的 CPU 架构：%s"; en="Unsupported CPU architecture: %s" ;;
    fetching_release) zh="正在获取发行信息：%s"; en="Fetching release metadata: %s" ;;
    release_line)     zh="发行版本 %s · 资产 %s"; en="Release %s · asset %s" ;;
    downloading)      zh="正在下载 %s"; en="Downloading %s" ;;
    verifying)        zh="校验 SHA-256 …"; en="Verifying SHA-256 …" ;;
    verify_ok)        zh="SHA-256 校验通过。"; en="SHA-256 verified." ;;
    verify_failed)    zh="SHA-256 校验失败！请通过可信渠道重新下载。"; en="SHA-256 mismatch! Re-download through a trusted channel." ;;
    no_digest)        zh="该资产未提供 SHA-256 摘要，已中止（可用 NW_SKIP_VERIFY=1 跳过）。"; en="Asset has no SHA-256 digest; aborted (set NW_SKIP_VERIFY=1 to skip)." ;;
    curl_failed)      zh="下载失败：%s"; en="Download failed: %s" ;;
    api_failed)       zh="GitHub API 请求失败：%s"; en="GitHub API request failed: %s" ;;
    installing_bin)   zh="安装二进制 → %s"; en="Installing binary → %s" ;;
    bin_ready)        zh="nowhere %s 已安装到 %s"; en="nowhere %s installed at %s" ;;
    extracting)       zh="解压发布包 …"; en="Extracting release archive …" ;;
    err_no_binary)    zh="发布包中未找到 nowhere 可执行文件。"; en="No nowhere executable found in the release archive." ;;
    role_prompt)      zh="请选择角色（Vector 客户端 / Portal 服务端 / Egress 远端出口）"; en="Select role (Vector client / Portal server / Egress remote exit)" ;;
    opt_portal)       zh="Portal —— 服务端中继（TLS+QUIC 监听）"; en="Portal —— server relay (TLS+QUIC listeners)" ;;
    opt_vector)       zh="Vector —— 客户端（本地 SOCKS5 入口）"; en="Vector —— client (local SOCKS5 ingress)" ;;
    opt_egress)       zh="Egress —— 远端出口（QUIC 回连 Portal，由它访问目标）"; en="Egress —— remote exit (QUIC back to Portal, reaches targets)" ;;
    key_prompt)       zh="共享密钥（32 位十六进制，两端必须一致）"; en="Shared key (32 hex chars, identical on both peers)" ;;
    opt_auto)     zh="自动生成新密钥"; en="Auto-generate a new key" ;;
    opt_manual)   zh="粘贴已有密钥"; en="Paste an existing key" ;;
    key_generated)    zh="已生成共享密钥：%s"; en="Generated shared key: %s" ;;
    key_invalid)      zh="密钥格式无效：需为 32 位小写十六进制字符。"; en="Invalid key: expected 32 lowercase hex characters." ;;
    morph_invalid)    zh="morph 取值无效：%s（应为 0 或 1）"; en="Invalid morph value: %s (expected 0 or 1)" ;;
    need_role)        zh="非交互模式必须指定角色：--role portal|vector|egress"; en="Non-interactive mode requires a role: --role portal|vector|egress" ;;
    svc_action_prompt) zh="服务操作（start/stop/restart）"; en="Service action (start/stop/restart)" ;;
    port_prompt)      zh="Portal 监听端口"; en="Portal listen port" ;;
    port_invalid)     zh="端口无效：%s（应为 1-65535）"; en="Invalid port: %s (expected 1-65535)" ;;
    layout_prompt)    zh="载体布局（TCP=TLS，UDP=QUIC）"; en="Carrier layout (TCP=TLS, UDP=QUIC)" ;;
    opt_same)  zh="同一端口同时提供 TCP+UDP"; en="One shared port for TCP+UDP" ;;
    opt_split) zh="TCP 与 UDP 使用不同端口"; en="Separate TCP and UDP ports" ;;
    opt_tcp)   zh="仅 TCP（TLS）"; en="TCP only (TLS)" ;;
    opt_udp)   zh="仅 UDP（QUIC）"; en="UDP only (QUIC)" ;;
    tcp_port_prompt)  zh="TCP（TLS）端口"; en="TCP (TLS) port" ;;
    udp_port_prompt)  zh="UDP（QUIC）端口"; en="UDP (QUIC) port" ;;
    exit_prompt)      zh="出口方式（Portal 如何访问目标）"; en="Exit mode (how Portal reaches targets)" ;;
    opt_direct)  zh="direct —— 本机直接访问"; en="direct —— reach targets from this host" ;;
    opt_socks)   zh="SOCKS5 —— 通过上游代理"; en="SOCKS5 —— via an upstream proxy" ;;
    socks_prompt)     zh="SOCKS5 上游 [user:pass@]host:port"; en="SOCKS5 upstream [user:pass@]host:port" ;;
    egress_needs_udp) zh="out=egress 需要 QUIC 监听，已自动启用 UDP 载体。"; en="out=egress requires a QUIC listener; UDP carrier auto-enabled." ;;
    morph_prompt)     zh="Morph 线路伪装（0=关闭，1=开启，默认 1，两端需一致）"; en="Morph wire masking (0=off, 1=on, default 1, peers must agree)" ;;
    tls_prompt)       zh="TLS 证书"; en="TLS certificate" ;;
    opt_selfsigned)     zh="自签名（客户端使用 pin 校验）"; en="Self-signed (clients verify with pin)" ;;
    opt_supplied)    zh="使用已有 PEM 证书链/私钥"; en="Use existing PEM chain/key files" ;;
    crt_prompt)       zh="证书链 PEM 路径"; en="Certificate chain PEM path" ;;
    keyfile_prompt)   zh="私钥 PEM 路径"; en="Private key PEM path" ;;
    err_cert_missing) zh="证书或私钥文件不存在：%s"; en="Certificate or key file not found: %s" ;;
    host_prompt)      zh="Portal 地址（域名或 IP）"; en="Portal address (domain or IP)" ;;
    host_required)    zh="必须提供 Portal 地址（--portal-host）。"; en="Portal address is required (--portal-host)." ;;
    net_prompt)       zh="连接载体"; en="Connection carrier" ;;
    opt_net_tcp)      zh="TCP（TLS）"; en="TCP (TLS)" ;;
    opt_net_udp)      zh="UDP（QUIC）"; en="UDP (QUIC)" ;;
    in_prompt)        zh="本地 SOCKS5 监听地址"; en="Local SOCKS5 listen address" ;;
    inauth_prompt)    zh="SOCKS5 认证 user:pass（留空关闭认证）"; en="SOCKS5 auth user:pass (empty = no auth)" ;;
    pin_prompt)       zh="立即获取 Portal 证书指纹并写入 pin？"; en="Fetch the Portal certificate fingerprint into pin now?" ;;
    pin_fetched)      zh="证书指纹（SHA-256）：%s"; en="Certificate fingerprint (SHA-256): %s" ;;
    pin_failed)       zh="无法获取证书指纹：%s"; en="Could not fetch certificate fingerprint: %s" ;;
    pin_applied)      zh="已将 pin 写入实例 %s 并重启服务。"; en="Pin written to instance %s and service restarted." ;;
    pin_portal_note)  zh="Portal 自身不使用 pin；请把上面的指纹交给 Vector/Egress 客户端使用。"; en="Portal itself does not use pin; hand the fingerprint above to Vector/Egress clients." ;;
    rate_prompt)      zh="上传限速 Mbps（0=不限）"; en="Upload limit Mbps (0 = unlimited)" ;;
    etar_prompt)      zh="下载限速 Mbps（0=不限）"; en="Download limit Mbps (0 = unlimited)" ;;
    name_prompt)      zh="实例名称（用于服务名 nowhere-<名称>）"; en="Instance name (service becomes nowhere-<name>)" ;;
    name_invalid)     zh="实例名称只能包含字母、数字、-、_、.；%s"; en="Instance name may only contain letters, digits, -, _, .; %s" ;;
    public_prompt)    zh="对外地址（用于生成客户端链接，留空自动探测）"; en="Public address for client links (empty = auto-detect)" ;;
    overwrite)        zh="实例 %s 已存在，覆盖它？"; en="Instance %s already exists — overwrite?" ;;
    configuring)      zh="正在配置实例 %s …"; en="Configuring instance %s …" ;;
    service_started)  zh="服务 nowhere-%s 已启用并启动。"; en="Service nowhere-%s enabled and started." ;;
    service_failed)   zh="服务启动失败，请用 nw logs %s 排查。"; en="Service failed to start; inspect with nw logs %s." ;;
    no_systemd)       zh="未检测到 systemd，已跳过服务注册；前台运行：nw run %s"; en="systemd not detected; skipped service registration. Foreground: nw run %s" ;;
    sum_role)         zh="角色"; en="Role" ;;
    sum_service)      zh="服务"; en="Service" ;;
    sum_url)          zh="运行 URL"; en="Runtime URL" ;;
    sum_version)      zh="版本"; en="Version" ;;
    sum_config)       zh="配置目录"; en="Config directory" ;;
    sum_links)        zh="客户端链接"; en="Client links" ;;
    link_vector_hint) zh="（Vector 客户端：指向 SOCKS5 in= 即可翻墙）"; en="(Vector client: point apps at the SOCKS5 in= address)" ;;
    link_share_hint)  zh="（nowhere:// 分享链接，可用于 Anywhere 等客户端）"; en="(nowhere:// share link for Anywhere and friends)" ;;
    link_egress_hint) zh="（Egress 只需回连 Portal，无需公网入口端口）"; en="(Egress dials out; no inbound port needed)" ;;
    qr_missing)       zh="未安装 qrencode，跳过二维码（apt install qrencode 后可显示）。"; en="qrencode not installed; QR skipped (apt install qrencode)." ;;
    fw_ufw)           zh="防火墙(ufw)：ufw allow %s/tcp && ufw allow %s/udp"; en="Firewall (ufw): ufw allow %s/tcp && ufw allow %s/udp" ;;
    fw_firewalld)     zh="防火墙(firewalld)：firewall-cmd --permanent --add-port=%s/tcp --add-port=%s/udp && firewall-cmd --reload"; en="Firewall (firewalld): firewall-cmd --permanent --add-port=%s/tcp --add-port=%s/udp && firewall-cmd --reload" ;;
    fw_iptables)      zh="防火墙(iptables)：请放行 TCP/UDP %s"; en="Firewall (iptables): allow TCP/UDP %s" ;;
    fw_cloud)         zh="别忘了同时在云厂商安全组放行上述端口。"; en="Also open the ports in your cloud provider security group." ;;
    fw_opened)        zh="已通过 %s 放行端口。"; en="Ports allowed via %s." ;;
    err_no_instance)  zh="实例不存在：%s"; en="Instance not found: %s" ;;
    err_no_instances) zh="尚未安装任何实例，先运行：bash nw.sh"; en="No instances installed yet; run: bash nw.sh" ;;
    inst_header)      zh="实例"; en="Instance" ;;
    inst_role)        zh="角色"; en="Role" ;;
    inst_state)       zh="状态"; en="State" ;;
    inst_url)         zh="URL"; en="URL" ;;
    stats_title)      zh="nowhere status（本地实例遥测）"; en="nowhere status (local telemetry)" ;;
    stats_failed)     zh="nowhere status 执行失败（可能没有运行中的实例）。"; en="nowhere status failed (no running instances?)." ;;
    uninstall_ask)    zh="确认卸载 %s？此操作不可恢复。"; en="Uninstall %s? This cannot be undone." ;;
    uninstall_done)   zh="已卸载：%s"; en="Uninstalled: %s" ;;
    uninstall_bin)    zh="同时删除 nowhere 二进制？"; en="Remove the nowhere binary as well?" ;;
    uninstall_bin_done) zh="已删除 %s"; en="Removed %s" ;;
    uninstall_all_done) zh="全部实例已卸载。"; en="All instances uninstalled." ;;
    update_self)      zh="更新管理脚本自身 …"; en="Updating the manager script itself …" ;;
    update_self_ok)   zh="脚本已更新（重启 nw 后生效）。"; en="Script updated (restart nw to apply)." ;;
    update_self_skip) zh="脚本自更新失败（网络或权限问题），已跳过。"; en="Script self-update skipped (network or permission issue)." ;;
    update_done)      zh="更新完成：%s"; en="Update complete: %s" ;;
    restarting)       zh="重启实例 %s …"; en="Restarting instance %s …" ;;
    lang_saved)       zh="界面语言已切换为中文。"; en="UI language switched to English." ;;
    lang_prompt)      zh="选择界面语言"; en="Select UI language" ;;
    opt_lang_zh)      zh="中文"; en="Chinese" ;;
    opt_lang_en)      zh="英文"; en="English" ;;
    logs_hint)        zh="正在跟踪 nowhere-%s 日志（Ctrl-C 退出）…"; en="Following nowhere-%s logs (Ctrl-C to exit) …" ;;
    run_hint)         zh="以前台模式运行 nowhere-%s（Ctrl-C 停止）…"; en="Running nowhere-%s in the foreground (Ctrl-C to stop) …" ;;
    version_line)     zh="nw.sh %s · nowhere %s"; en="nw.sh %s · nowhere %s" ;;
    version_unknown)  zh="未知"; en="unknown" ;;
    err_unknown_arg)  zh="未知参数：%s（用 nw.sh help 查看帮助）"; en="Unknown option: %s (see nw.sh help)" ;;
    err_unknown_cmd)  zh="未知命令：%s（用 nw.sh help 查看帮助）"; en="Unknown command: %s (see nw.sh help)" ;;
    wizard_done)      zh="安装完成。使用 nw menu 打开管理菜单。"; en="Done. Run nw menu for the management menu." ;;
    cancelled)        zh="已取消，未做任何更改。"; en="Cancelled; nothing was changed." ;;
    public_detected)  zh="自动探测到对外地址：%s"; en="Auto-detected public address: %s" ;;
    public_failed)    zh="无法自动探测对外地址，请用 --public-addr 指定。"; en="Could not auto-detect the public address; use --public-addr." ;;
    choose_hint)      zh="输入编号，直接回车取默认值"; en="Enter a number, or press Enter for the default" ;;
    confirm_default)  zh="确认"; en="Confirm" ;;
    probe_usage)      zh="用法：nw.sh probe <实例名|vector://URL> <目标 主机:端口>"; en="Usage: nw.sh probe <instance|vector://URL> <target host:port>" ;;
    probe_running)    zh="正在探测 %s …"; en="Probing %s …" ;;
    err_target)       zh="探测目标无效：%s"; en="Invalid probe target: %s" ;;
    need_instance_arg) zh="请指定实例名（或用 --all）。"; en="Specify an instance name (or --all)." ;;
    key_rotated_note) zh="注意：修改密钥后，两端必须使用相同密钥。"; en="Note: after changing the key, both peers must use the same value." ;;
    *) zh=""; en="$id" ;;
  esac
  if [ "${NW_LANG_CODE:-en}" = zh ]; then out="${zh:-$en}"; else out="${en:-$zh}"; fi
  if [ "$#" -gt 0 ]; then
    # shellcheck disable=SC2059  # translated format string with %s slots
    printf "$out" "$@"
  else
    printf '%s' "$out"
  fi
}

# ============================== output helpers ==============================
say()  { printf '%s\n' "$(t "$@")"; }
info() { printf '%s*%s %s\n' "$C_BLUE" "$C_RESET" "$(t "$@")"; }
ok()   { printf '%s+%s %s\n' "$C_GREEN" "$C_RESET" "$(t "$@")"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t "$@")" >&2; }
die()  { printf '%sx%s %s\n' "$C_RED" "$C_RESET" "$(t "$@")" >&2; exit 1; }

# ============================== prompts =====================================
have_tty() { [ -t 0 ]; }

# ask <var> <id> <default> [printf args...]
ask() {
  local __var="$1" __id="$2" __def="${3:-}"
  shift 3 || shift $#
  local __prompt __line=""
  if [ "$#" -gt 0 ]; then __prompt="$(t "$__id" "$@")"; else __prompt="$(t "$__id")"; fi
  if have_tty; then
    if [ -n "$__def" ]; then printf '%s [%s]: ' "$__prompt" "$__def"
    else printf '%s: ' "$__prompt"; fi
    IFS= read -r __line || __line=""
  fi
  [ -z "$__line" ] && __line="$__def"
  printf -v "$__var" '%s' "$__line"
}

# confirm <id> <default y|n> [printf args...]
confirm() {
  local __id="$1" __def="${2:-n}"
  shift 2 || shift $#
  local __prompt __line="" __hint
  if [ "$#" -gt 0 ]; then __prompt="$(t "$__id" "$@")"; else __prompt="$(t "$__id")"; fi
  case "$__def" in y|Y) __hint="[Y/n]" ;; *) __hint="[y/N]" ;; esac
  if have_tty; then
    printf '%s %s: ' "$__prompt" "$__hint"
    IFS= read -r __line || __line=""
  fi
  [ -z "$__line" ] && __line="$__def"
  case "$__line" in
    [Yy]|[Yy][Ee][Ss]|1) return 0 ;;
    *) return 1 ;;
  esac
}

# choose <var> <id> <default> <value> [value...]  — numbered menu, values are
# also used as translation ids (opt_<value>).
choose() {
  local __var="$1" __id="$2" __def="$3"
  shift 3
  local __opts=("$@") __prompt __line="" i n
  __prompt="$(t "$__id")"
  if have_tty; then
    printf '%s\n' "$__prompt"
    n=${#__opts[@]}
    for i in "${!__opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "$(t "opt_${__opts[$i]}")"
    done
    printf '%s [%s]: ' "$(t choose_hint)" "$__def"
    IFS= read -r __line || __line=""
    [ -z "$__line" ] && __line="$__def"
    case "$__line" in
      [1-9]|[1-9][0-9])
        if [ "$__line" -ge 1 ] && [ "$__line" -le "$n" ]; then
          __line="${__opts[$((__line - 1))]}"
        fi ;;
    esac
  else
    __line="$__def"
  fi
  printf -v "$__var" '%s' "$__line"
}

# ============================== small utilities =============================
require_root() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  if [ "${NW_ASSUME_ROOT:-0}" = 1 ]; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    warn need_root
    exec sudo -E bash "$0" "$@"
  fi
  die sudo_missing
}

have() { command -v "$1" >/dev/null 2>&1; }

valid_port() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_hex_key() {
  case "${1:-}" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 32 ]
}

valid_pin() {
  case "${1:-}" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# percent-encode everything outside the unreserved set (RFC 3986)
pct_encode() {
  local s="${1:-}" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# split "[user:pass@]host:port" into CRED_USER / CRED_PASS / CRED_HOST / CRED_PORT
split_cred() {
  local s="${1:-}" cred="" hostport=""
  CRED_USER=""; CRED_PASS=""; CRED_HOST=""; CRED_PORT=""
  if [[ "$s" == *@* ]]; then
    cred="${s%@*}"        # credentials = everything before the LAST '@'
    hostport="${s##*@}"   # host:port  = everything after the LAST '@' 
    if [[ "$cred" == *:* ]]; then
      CRED_USER="${cred%%:*}"
      CRED_PASS="${cred#*:}"
    else
      CRED_USER="$cred"
    fi
  else
    hostport="$s"
  fi
  # bracketed IPv6 literal: [2001:db8::1]:443
  if [[ "$hostport" == \[*\]:* ]]; then
    CRED_HOST="${hostport%]:*}]"
    CRED_PORT="${hostport##*]:}"
  elif [[ "$hostport" == *:* ]]; then
    CRED_HOST="${hostport%:*}"
    CRED_PORT="${hostport##*:}"
  else
    CRED_HOST="$hostport"
  fi
}

# encode credentials for a URL query value: user:pass@host:port
encode_socks() {
  local s="${1:-}" out=""
  split_cred "$s"
  if [ -n "$CRED_USER" ]; then
    out="$(pct_encode "$CRED_USER")"
    [ -n "$CRED_PASS" ] && out+=":$(pct_encode "$CRED_PASS")"
    out+="@"
  fi
  out+="$CRED_HOST:$CRED_PORT"
  printf '%s' "$out"
}

bracket_host() {
  case "${1:-}" in
    \[*\]*) printf '%s' "$1" ;;
    *:*)     printf '[%s]' "$1" ;;
    *)       printf '%s' "$1" ;;
  esac
}

redact_key() {
  local k="${1:-}"
  if [ "${#k}" -ge 12 ]; then printf '%s..%s' "${k:0:4}" "${k: -4}"; else printf '%s' "$k"; fi
}

# ============================== platform / release ==========================
PLAT_ARCH=""; PLAT_OS=""; PLAT_LIBC=""; TARGET_TRIPLE=""; ASSET_NAME=""

detect_platform() {
  local machine os
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)  PLAT_ARCH=x86_64 ;;
    aarch64|arm64) PLAT_ARCH=aarch64 ;;
    armv7l|armv7*) PLAT_ARCH=armv7 ;;
    *)             PLAT_ARCH="$machine" ;;
  esac
  os="$(uname -s)"
  case "$os" in
    Linux)
      PLAT_OS=linux
      if ldd --version 2>&1 | grep -qi musl \
         || [ -f /etc/alpine-release ] \
         || ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        PLAT_LIBC=musl
      else
        PLAT_LIBC=gnu
      fi ;;
    FreeBSD) PLAT_OS=freebsd; PLAT_LIBC="" ;;
    Darwin)  PLAT_OS=darwin;  PLAT_LIBC="" ;;
    *) die err_os "$os" ;;
  esac
  case "$PLAT_OS" in
    linux)   TARGET_TRIPLE="${PLAT_ARCH}-unknown-linux-${PLAT_LIBC}" ;;
    freebsd) TARGET_TRIPLE="${PLAT_ARCH}-unknown-freebsd" ;;
    darwin)  TARGET_TRIPLE="${PLAT_ARCH}-apple-darwin" ;;
    *) die err_arch "$machine" ;;
  esac
  ASSET_NAME="nowhere-${TARGET_TRIPLE}.tar.gz"
}

REL_TAG=""; ASSET_URL=""; ASSET_SHA=""

api_get() {
  curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 \
       -H "Accept: application/vnd.github+json" -A "$CURL_UA" "$1"
}

resolve_release() {
  local want="${OPT_VERSION:-}" api json
  if [ -n "$want" ]; then
    case "$want" in v*) ;; *) want="v$want" ;; esac
    api="${UPSTREAM_API}/releases/tags/${want}"
  else
    api="${UPSTREAM_API}/releases/latest"
  fi
  info fetching_release "$api"
  json="$(api_get "$api")" || die api_failed "$api"
  if have python3; then
    local parsed
    parsed="$(python3 - "$json" "$ASSET_NAME" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(3)
name = sys.argv[2]
for a in data.get("assets", []):
    if a.get("name") == name:
        print(data.get("tag_name", ""))
        print(a.get("browser_download_url", ""))
        print((a.get("digest") or "").split(":", 1)[-1])
        sys.exit(0)
sys.exit(4)
PY
)" || die api_failed "asset ${ASSET_NAME} not found in release"
    REL_TAG="$(sed -n 1p <<<"$parsed")"
    ASSET_URL="$(sed -n 2p <<<"$parsed")"
    ASSET_SHA="$(sed -n 3p <<<"$parsed")"
  else
    # python3-less fallback: best-effort grep/sed parsing
    REL_TAG="$(grep -o '"tag_name"[^,]*' <<<"$json" | head -n1 | sed 's/.*: *"//; s/"//')"
    ASSET_URL="$(grep -o "\"browser_download_url\"[^,]*${ASSET_NAME}\"" <<<"$json" | head -n1 | sed 's/.*: *"//; s/"$//')"
    ASSET_SHA="$(grep -o '"digest"[^,]*' <<<"$json" | head -n1 | sed 's/.*sha256://; s/"//')"
  fi
  [ -n "$ASSET_URL" ] || die api_failed "asset ${ASSET_NAME} not found"
  info release_line "$REL_TAG" "$ASSET_NAME"
}

install_binary() {
  detect_platform
  info platform "$(uname -srm)" "$ASSET_NAME"

  local tmpdir="" bin=""
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  if [ -n "${NW_LOCAL_TARBALL:-}" ]; then
    info installing_bin "$NW_LOCAL_TARBALL"
    cp "$NW_LOCAL_TARBALL" "$tmpdir/asset"
  else
    resolve_release
    info downloading "$ASSET_URL"
    curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 -A "$CURL_UA" \
         -o "$tmpdir/asset" "$ASSET_URL" || die curl_failed "$ASSET_URL"
    if [ "${NW_SKIP_VERIFY:-0}" = 1 ]; then
      warn verify_ok # reuse: remind that verification was skipped
    elif [ -z "$ASSET_SHA" ]; then
      die no_digest
    else
      info verifying
      echo "${ASSET_SHA}  ${tmpdir}/asset" | sha256sum -c - >/dev/null 2>&1 \
        || die verify_failed
      ok verify_ok
    fi
  fi

  info extracting
  mkdir -p "$tmpdir/x"
  tar xzf "$tmpdir/asset" -C "$tmpdir/x"
  bin="$(find "$tmpdir/x" -type f -name nowhere -perm -u+x | head -n1)"
  [ -n "$bin" ] || bin="$(find "$tmpdir/x" -type f -name nowhere | head -n1)"
  [ -n "$bin" ] || die err_no_binary
  chmod 0755 "$bin"
  mkdir -p "$BIN_DIR"
  install -m 0755 "$bin" "$NOWHERE_BIN"
  VERSION="$(installed_version | tr -d '[:space:]')"
  if [ -z "$VERSION" ] || [ "$VERSION" = unknown ]; then
    VERSION="${REL_TAG:-${OPT_VERSION:-local}}"
  fi
  ok bin_ready "$VERSION" "$NOWHERE_BIN"
}

ensure_binary() {
  if [ -x "$NOWHERE_BIN" ] && [ -z "${OPT_VERSION:-}" ] && [ "${OPT_FORCE:-0}" != 1 ]; then
    VERSION="$(installed_version)"
    ok bin_ready "$VERSION" "$NOWHERE_BIN"
    return 0
  fi
  install_binary
}

installed_version() {
  local v=""
  if [ -x "$NOWHERE_BIN" ]; then
    # timeout guards against binaries that serve instead of answering
    if have timeout; then
      v="$(timeout 5 "$NOWHERE_BIN" --version 2>/dev/null | head -n1 || true)"
      [ -z "$v" ] && v="$(timeout 5 "$NOWHERE_BIN" version 2>/dev/null | head -n1 || true)"
    else
      v="$("$NOWHERE_BIN" --version 2>/dev/null | head -n1 || true)"
      [ -z "$v" ] && v="$("$NOWHERE_BIN" version 2>/dev/null | head -n1 || true)"
    fi
  fi
  v="${v//$'\n'/}"
  printf '%s' "${v:-unknown}"
}

# ============================== key / fingerprint ===========================
generate_key() {
  local out="" k=""
  if [ -x "$NOWHERE_BIN" ]; then
    out="$("$NOWHERE_BIN" generate-key 2>/dev/null || true)"
    k="$(grep -oE '[0-9a-f]{32}' <<<"$out" | tail -n1 || true)"
  fi
  if [ -z "$k" ] && have openssl; then
    k="$(openssl rand -hex 16)"
  fi
  [ -n "$k" ] || die key_invalid
  printf '%s' "$k"
}

# fetch_fingerprint <host> <port> <key> <morph> → prints sha256 hex or empty
fetch_fingerprint() {
  local host="$1" port="$2" key="$3" morph="${4:-1}" out="" hex=""
  [ -x "$NOWHERE_BIN" ] || return 1
  out="$("$NOWHERE_BIN" fingerprint "nowhere://${key}@$(bracket_host "$host"):${port}?morph=${morph}" 2>&1 || true)"
  hex="$(grep -oE '\b[0-9a-f]{64}\b' <<<"$out" | head -n1 || true)"
  printf '%s' "$hex"
}

# ============================== instance state ==============================
# Config state (also the on-disk meta schema)
ROLE=""; NAME=""; KEY=""; MORPH="1"
PORT="2000"; TCP_PORT=""; UDP_PORT=""; TCP_CARRIER=""; UDP_CARRIER=""
OUT="direct"; SOCKS=""; TLS="1"; CRT=""; KEY_PATH=""
PORTAL_HOST=""; PORTAL_PORT="2000"; NET="tcp"
IN="127.0.0.1:1080"; IN_USER=""; IN_PASS=""
PIN=""; SNI=""; RATE=""; ETAR=""
PUBLIC_ADDR=""; VERSION=""; CREATED=""; UPDATED=""; URL=""

instance_dir() { printf '%s/%s' "$ETC_DIR" "$1"; }
instance_url_file() { printf '%s/url' "$(instance_dir "$1")"; }
instance_meta_file() { printf '%s/meta' "$(instance_dir "$1")"; }
instance_wrapper() { printf '%s/nowhere-%s' "$BIN_DIR" "$1"; }
instance_unit() { printf '/etc/systemd/system/nowhere-%s.service' "$1"; }

instance_exists() { [ -f "$(instance_url_file "$1")" ]; }

list_instances() {
  local d n
  for d in "$ETC_DIR"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ -f "$d/url" ] && printf '%s\n' "$n"
  done
  return 0
}

load_instance() {
  local name="$1" f
  f="$(instance_meta_file "$name")"
  [ -f "$f" ] || die err_no_instance "$name"
  ROLE=""; NAME="$name"; KEY=""; MORPH="1"
  PORT="2000"; TCP_PORT=""; UDP_PORT=""; TCP_CARRIER=""; UDP_CARRIER=""
  OUT="direct"; SOCKS=""; TLS="1"; CRT=""; KEY_PATH=""
  PORTAL_HOST=""; PORTAL_PORT="2000"; NET="tcp"
  IN="127.0.0.1:1080"; IN_USER=""; IN_PASS=""
  PIN=""; SNI=""; RATE=""; ETAR=""
  PUBLIC_ADDR=""; VERSION=""; CREATED=""; UPDATED=""; URL=""
  # shellcheck disable=SC1090
  . "$f"
  URL="$(cat "$(instance_url_file "$name")")"
}

save_instance() {
  local dir; dir="$(instance_dir "$NAME")"
  mkdir -p "$dir"
  chmod 0750 "$dir"
  UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$CREATED" ] || CREATED="$UPDATED"
  cat >"$(instance_meta_file "$NAME")" <<EOF
# Nowhere instance metadata — generated by nw.sh ${NW_VERSION}
# 由此文件与 url 文件共同描述实例；服务启动读取 url 文件。
ROLE="${ROLE}"
NAME="${NAME}"
KEY="${KEY}"
MORPH="${MORPH}"
PORT="${PORT}"
TCP_PORT="${TCP_PORT}"
UDP_PORT="${UDP_PORT}"
TCP_CARRIER="${TCP_CARRIER}"
UDP_CARRIER="${UDP_CARRIER}"
OUT="${OUT}"
SOCKS="${SOCKS}"
TLS="${TLS}"
CRT="${CRT}"
KEY_PATH="${KEY_PATH}"
PORTAL_HOST="${PORTAL_HOST}"
PORTAL_PORT="${PORTAL_PORT}"
NET="${NET}"
IN="${IN}"
IN_USER="${IN_USER}"
IN_PASS="${IN_PASS}"
PIN="${PIN}"
SNI="${SNI}"
RATE="${RATE}"
ETAR="${ETAR}"
PUBLIC_ADDR="${PUBLIC_ADDR}"
VERSION="${VERSION}"
CREATED="${CREATED}"
UPDATED="${UPDATED}"
EOF
  chmod 0640 "$(instance_meta_file "$NAME")"
  printf '%s\n' "$URL" >"$(instance_url_file "$NAME")"
  chmod 0640 "$(instance_url_file "$NAME")"

  # runtime env template (tuning knobs, all optional)
  cat >"${dir}/env" <<'EOF'
# Optional Nowhere runtime tuning — uncomment to override.
# See https://github.com/NodePassProject/Nowhere/blob/main/docs/configuration.md
# NOW_TCP_DATA_BUF_SIZE=32768
# NOW_UDP_DATA_BUF_SIZE=65536
# NOW_HANDSHAKE_TIMEOUT=5s
# NOW_FLOW_SETUP_TIMEOUT=20s
# NOW_UDP_IDLE_TIMEOUT=120s
# NOW_TRANSPORT_MEMORY_PROFILE=throughput
# NOW_MORPH_TCP_PRELUDE=fade
EOF
  chmod 0640 "${dir}/env"
  write_wrapper
  write_unit
}

write_wrapper() {
  local w; w="$(instance_wrapper "$NAME")"
  cat >"$w" <<EOF
#!/usr/bin/env bash
# Nowhere instance "${NAME}" — generated by nw.sh; do not edit (use nw.sh).
set -euo pipefail
exec "${NOWHERE_BIN}" "\$(cat "$(instance_url_file "$NAME")")"
EOF
  chmod 0755 "$w"
}

write_unit() {
  if ! systemd_available; then return 0; fi
  local unit lowport=""
  unit="$(instance_unit "$NAME")"
  for p in "$PORT" "$TCP_PORT" "$UDP_PORT" "$PORTAL_PORT"; do
    if valid_port "$p" && [ "$p" -lt 1024 ]; then lowport=1; fi
  done
  if [ "$ROLE" = vector ]; then
    split_cred "$IN"
    if valid_port "$CRED_PORT" && [ "$CRED_PORT" -lt 1024 ]; then lowport=1; fi
  fi
  cat >"$unit" <<EOF
[Unit]
Description=Nowhere ${ROLE} (${NAME})
Documentation=https://github.com/NodePassProject/Nowhere
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ETC_DIR}/${NAME}/env
ExecStart=$(instance_wrapper "$NAME")
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
LimitNOFILE=1048576
NoNewPrivileges=true
EOF
  if [ -n "$lowport" ]; then
    printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n' >>"$unit"
  fi
  cat >>"$unit" <<EOF
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nowhere-${NAME}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

systemd_available() {
  [ "${NW_SKIP_SERVICE:-0}" != 1 ] && have systemctl && [ -d /run/systemd/system ]
}

svc() { # svc <action> <name>
  systemctl "$1" "nowhere-$2.service"
}

svc_state() {
  systemctl is-active "nowhere-$1.service" 2>/dev/null || true
}

# ============================== URL building ================================
build_url() {
  local q=() endpoint="" outv="" inv=""
  case "$ROLE" in
    portal)
      if [ -n "$TCP_CARRIER" ] && [ -n "$UDP_CARRIER" ]; then
        if [ "$TCP_CARRIER" = tcp ] && [ "$UDP_CARRIER" = udp ] && [ "$TCP_PORT" = "$UDP_PORT" ]; then
          endpoint="*:${PORT}"
        else
          endpoint="*/${TCP_CARRIER}:${TCP_PORT}/${UDP_CARRIER}:${UDP_PORT}"
        fi
      elif [ -n "$TCP_CARRIER" ]; then
        endpoint="*/${TCP_CARRIER}:${PORT}"
      elif [ -n "$UDP_CARRIER" ]; then
        endpoint="*/${UDP_CARRIER}:${PORT}"
      else
        endpoint="*:${PORT}"
      fi
      URL="portal://${KEY}@${endpoint}"
      case "$OUT" in
        direct) ;;
        egress) q+=("out=egress") ;;
        *)      q+=("out=$(encode_socks "$SOCKS")") ;;
      esac
      [ "$TLS" = 2 ] && q+=("tls=2" "crt=$(pct_encode "$CRT")" "key=$(pct_encode "$KEY_PATH")")
      [ "$MORPH" = 0 ] && q+=("morph=0")
      [ -n "$RATE" ] && q+=("rate=${RATE}")
      [ -n "$ETAR" ] && q+=("etar=${ETAR}")
      ;;
    vector)
      if [ "$NET" = udp ]; then
        endpoint="$(bracket_host "$PORTAL_HOST")/udp:${PORTAL_PORT}"
      else
        endpoint="$(bracket_host "$PORTAL_HOST"):${PORTAL_PORT}"
      fi
      URL="vector://${KEY}@${endpoint}"
      inv=""
      [ -n "$IN_USER" ] && { inv="$(pct_encode "$IN_USER")"; [ -n "$IN_PASS" ] && inv+=":$(pct_encode "$IN_PASS")"; inv+="@"; }
      inv+="$IN"
      q+=("in=${inv}")
      [ -n "$SNI" ] && q+=("sni=${SNI}")
      [ -n "$PIN" ] && q+=("pin=${PIN}")
      [ "$MORPH" = 0 ] && q+=("morph=0")
      [ -n "$RATE" ] && q+=("rate=${RATE}")
      [ -n "$ETAR" ] && q+=("etar=${ETAR}")
      ;;
    egress)
      endpoint="$(bracket_host "$PORTAL_HOST")/udp:${PORTAL_PORT}"
      URL="egress://${KEY}@${endpoint}"
      [ -n "$SNI" ] && q+=("sni=${SNI}")
      [ -n "$PIN" ] && q+=("pin=${PIN}")
      [ "$MORPH" = 0 ] && q+=("morph=0")
      [ -n "$RATE" ] && q+=("rate=${RATE}")
      [ -n "$ETAR" ] && q+=("etar=${ETAR}")
      ;;
    *) die err_unknown_cmd "$ROLE" ;;
  esac
  if [ "${#q[@]}" -gt 0 ]; then
    local joined; joined="$(IFS='&'; echo "${q[*]}")"
    URL="${URL}?${joined}"
  fi
}

# ============================== validation ==================================
validate_state() {
  case "$ROLE" in
    portal|vector|egress) ;;
    *) die err_unknown_cmd "${ROLE:-<empty>}" ;;
  esac
  case "$NAME" in
    [A-Za-z0-9]*) ;;
    *) die name_invalid "$NAME" ;;
  esac
  case "$NAME" in
    *[!A-Za-z0-9._-]*) die name_invalid "$NAME" ;;
  esac
  valid_hex_key "$KEY" || die key_invalid
  case "$MORPH" in 0|1) ;; *) die morph_invalid "$MORPH" ;; esac
  if [ -n "$PIN" ]; then valid_pin "$PIN" || die pin_failed "pin"; fi
  if [ -n "$RATE" ]; then case "$RATE" in ''|*[!0-9]*) die port_invalid "rate=$RATE" ;; esac; fi
  if [ -n "$ETAR" ]; then case "$ETAR" in ''|*[!0-9]*) die port_invalid "etar=$ETAR" ;; esac; fi
  if [ "$ROLE" = portal ]; then
    valid_port "$PORT" || die port_invalid "$PORT"
    if [ -n "$TCP_PORT" ]; then valid_port "$TCP_PORT" || die port_invalid "$TCP_PORT"; fi
    if [ -n "$UDP_PORT" ]; then valid_port "$UDP_PORT" || die port_invalid "$UDP_PORT"; fi
    if [ "$TLS" = 2 ]; then
      [ -f "$CRT" ] || die err_cert_missing "$CRT"
      [ -f "$KEY_PATH" ] || die err_cert_missing "$KEY_PATH"
    fi
  fi
  if [ "$ROLE" = vector ] || [ "$ROLE" = egress ]; then
    [ -n "$PORTAL_HOST" ] || die host_required
    valid_port "$PORTAL_PORT" || die port_invalid "$PORTAL_PORT"
    case "$NET" in tcp|udp) ;; *) die err_unknown_arg "net=$NET" ;; esac
  fi
}

# ============================== wizards =====================================
copy_options_to_state() {
  [ -n "$OPT_ROLE" ] && ROLE="$OPT_ROLE"
  [ -n "$OPT_NAME" ] && NAME="$OPT_NAME"
  [ -n "$OPT_KEY" ] && KEY="$OPT_KEY"
  [ -n "$OPT_MORPH" ] && MORPH="$OPT_MORPH"
  [ -n "$OPT_PORT" ] && PORT="$OPT_PORT"
  [ -n "$OPT_TCP_PORT" ] && TCP_PORT="$OPT_TCP_PORT"
  [ -n "$OPT_UDP_PORT" ] && UDP_PORT="$OPT_UDP_PORT"
  [ -n "$OPT_OUT" ] && OUT="$OPT_OUT"
  [ -n "$OPT_SOCKS" ] && SOCKS="$OPT_SOCKS"
  [ -n "$OPT_TLS" ] && TLS="$OPT_TLS"
  [ -n "$OPT_CRT" ] && CRT="$OPT_CRT"
  [ -n "$OPT_KEY_PATH" ] && KEY_PATH="$OPT_KEY_PATH"
  [ -n "$OPT_PORTAL_HOST" ] && PORTAL_HOST="$OPT_PORTAL_HOST"
  [ -n "$OPT_PORTAL_PORT" ] && PORTAL_PORT="$OPT_PORTAL_PORT"
  [ -n "$OPT_NET" ] && NET="$OPT_NET"
  [ -n "$OPT_IN" ] && IN="$OPT_IN"
  [ -n "$OPT_IN_AUTH" ] && IN_AUTH="$OPT_IN_AUTH"
  [ -n "$OPT_PIN" ] && PIN="$OPT_PIN"
  [ -n "$OPT_SNI" ] && SNI="$OPT_SNI"
  [ -n "$OPT_RATE" ] && RATE="$OPT_RATE"
  [ -n "$OPT_ETAR" ] && ETAR="$OPT_ETAR"
  [ -n "$OPT_PUBLIC_ADDR" ] && PUBLIC_ADDR="$OPT_PUBLIC_ADDR"
  if [ -n "$OPT_IN_AUTH" ]; then
    IN_USER="${OPT_IN_AUTH%%:*}"
    IN_PASS="${OPT_IN_AUTH#*:}"
    [ "$IN_PASS" = "$IN_USER" ] && IN_PASS=""
  fi
  if [ -n "$OPT_CARRIER" ]; then
    case "$OPT_CARRIER" in
      same|both) TCP_CARRIER=tcp; UDP_CARRIER=udp; TCP_PORT="$PORT"; UDP_PORT="$PORT" ;;
      split)
        TCP_CARRIER=tcp; UDP_CARRIER=udp
        [ -n "$TCP_PORT" ] || TCP_PORT="$PORT"
        [ -n "$UDP_PORT" ] || UDP_PORT="$((PORT + 1))"
        ;;
      tcp)       TCP_CARRIER=tcp; UDP_CARRIER=""; TCP_PORT="$PORT" ;;
      udp)       TCP_CARRIER=""; UDP_CARRIER=udp; UDP_PORT="$PORT" ;;
      *) die err_unknown_arg "carrier=$OPT_CARRIER" ;;
    esac
  elif [ -n "$OPT_TCP_CARRIER" ] || [ -n "$OPT_UDP_CARRIER" ]; then
    TCP_CARRIER="$OPT_TCP_CARRIER"
    UDP_CARRIER="$OPT_UDP_CARRIER"
    [ -n "$TCP_PORT" ] || TCP_PORT="$PORT"
    [ -n "$UDP_PORT" ] || UDP_PORT="$PORT"
  fi
  # out=egress requires a QUIC listener
  if [ "$ROLE" = portal ] && [ "$OUT" = egress ] && [ -z "$UDP_CARRIER" ]; then
    warn egress_needs_udp
    UDP_CARRIER=udp
    UDP_PORT="$PORT"
  fi
}

wizard_common_key() {
  local mode=""
  if [ -n "$OPT_KEY" ]; then KEY="$OPT_KEY"; return; fi
  if [ "$OPT_YES" = 1 ] || ! have_tty; then
    KEY="$(generate_key)"
    say key_generated "$KEY"
    return
  fi
  choose mode key_prompt auto auto manual
  if [ "$mode" = manual ]; then
    ask KEY key_prompt ""
    valid_hex_key "$KEY" || die key_invalid
  else
    KEY="$(generate_key)"
    say key_generated "$KEY"
  fi
}

wizard_portal() {
  if [ -z "$OPT_PORT" ] && { [ "$OPT_YES" = 1 ] || ! have_tty; }; then PORT=2000; fi
  if have_tty && [ "$OPT_YES" != 1 ]; then
    local layout=""
    ask PORT port_prompt "$PORT"
    valid_port "$PORT" || die port_invalid "$PORT"
    choose layout layout_prompt same same split tcp udp
    case "$layout" in
      same) TCP_CARRIER=tcp; UDP_CARRIER=udp; TCP_PORT="$PORT"; UDP_PORT="$PORT" ;;
      split)
        TCP_CARRIER=tcp; UDP_CARRIER=udp
        ask TCP_PORT tcp_port_prompt "$PORT"; valid_port "$TCP_PORT" || die port_invalid "$TCP_PORT"
        ask UDP_PORT udp_port_prompt "$((PORT + 1))"; valid_port "$UDP_PORT" || die port_invalid "$UDP_PORT"
        ;;
      tcp)  TCP_CARRIER=tcp; UDP_CARRIER=""; TCP_PORT="$PORT" ;;
      udp)  TCP_CARRIER=""; UDP_CARRIER=udp; UDP_PORT="$PORT" ;;
    esac
    local exit_mode=""
    choose exit_mode exit_prompt "$OUT" direct socks egress
    OUT="$exit_mode"
    if [ "$OUT" = socks ]; then
      ask SOCKS socks_prompt "127.0.0.1:1080"
    fi
    if [ "$OUT" = egress ] && [ -z "$UDP_CARRIER" ]; then
      warn egress_needs_udp
      UDP_CARRIER=udp; UDP_PORT="$PORT"
    fi
    ask MORPH morph_prompt "$MORPH"
    local tls_mode=""
    choose tls_mode tls_prompt selfsigned selfsigned supplied
    if [ "$tls_mode" = supplied ]; then
      TLS=2
      ask CRT crt_prompt "/etc/nowhere/cert.pem"
      ask KEY_PATH keyfile_prompt "/etc/nowhere/key.pem"
    fi
  fi
  wizard_common_key
}

wizard_vector() {
  if have_tty && [ "$OPT_YES" != 1 ]; then
    ask PORTAL_HOST host_prompt "${PORTAL_HOST:-relay.example.com}"
    ask PORTAL_PORT port_prompt "$PORTAL_PORT"
    valid_port "$PORTAL_PORT" || die port_invalid "$PORTAL_PORT"
    local net=""
    choose net net_prompt "$NET" tcp udp
    NET="$net"
    ask IN in_prompt "$IN"
    ask IN_AUTH inauth_prompt ""
    IN_USER="${IN_AUTH%%:*}"
    IN_PASS="${IN_AUTH#*:}"
    [ "$IN_PASS" = "$IN_USER" ] && IN_PASS=""
    ask MORPH morph_prompt "$MORPH"
    ask RATE rate_prompt "$RATE"
    ask ETAR etar_prompt "$ETAR"
  elif [ -z "$PORTAL_HOST" ]; then
    die host_required
  fi
  wizard_common_key
  if [ -z "$PIN" ] && [ "$OPT_YES" != 1 ] && have_tty; then
    if confirm pin_prompt y; then
      try_fetch_pin
    fi
  fi
}

wizard_egress() {
  if have_tty && [ "$OPT_YES" != 1 ]; then
    ask PORTAL_HOST host_prompt "${PORTAL_HOST:-relay.example.com}"
    ask PORTAL_PORT udp_port_prompt "$PORTAL_PORT"
    valid_port "$PORTAL_PORT" || die port_invalid "$PORTAL_PORT"
    ask MORPH morph_prompt "$MORPH"
    ask RATE rate_prompt "$RATE"
    ask ETAR etar_prompt "$ETAR"
  elif [ -z "$PORTAL_HOST" ]; then
    die host_required
  fi
  wizard_common_key
  if [ -z "$PIN" ] && [ "$OPT_YES" != 1 ] && have_tty; then
    if confirm pin_prompt y; then
      try_fetch_pin
    fi
  fi
}

try_fetch_pin() {
  local hex=""
  hex="$(fetch_fingerprint "$PORTAL_HOST" "$PORTAL_PORT" "$KEY" "$MORPH" || true)"
  if [ -n "$hex" ]; then
    ok pin_fetched "$hex"
    PIN="$hex"
  else
    warn pin_failed "$PORTAL_HOST:$PORTAL_PORT"
  fi
}

# ============================== public address ==============================
detect_public_addr() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsSL --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || true)"
    ip="$(tr -d '[:space:]' <<<"$ip")"
    case "$ip" in
      *[!0-9a-fA-F.:]*) ip="" ;;
      ???????????????????????????????????????????????*) ip="" ;; # sanity length cap (46)
    esac
    [ -n "$ip" ] && break
  done
  if [ -z "$ip" ] && have hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$ip"
}

# ============================== commands ====================================
cmd_install() {
  require_root "$@"
  ensure_binary

  if [ -z "$OPT_ROLE" ]; then
    local r=""
    if [ "$OPT_YES" = 1 ] || ! have_tty; then
      die need_role
    fi
    choose r role_prompt portal portal vector egress
    OPT_ROLE="$r"
  fi

  # reset state, then apply CLI options
  ROLE="${OPT_ROLE}"; NAME="${OPT_NAME:-$ROLE}"; KEY=""; MORPH="1"
  PORT="${OPT_PORT:-2000}"; TCP_PORT=""; UDP_PORT=""; TCP_CARRIER=""; UDP_CARRIER=""
  OUT="direct"; SOCKS=""; TLS="1"; CRT=""; KEY_PATH=""
  PORTAL_HOST=""; PORTAL_PORT="2000"; NET="tcp"
  IN="127.0.0.1:1080"; IN_USER=""; IN_PASS=""
  PIN=""; SNI=""; RATE=""; ETAR=""
  PUBLIC_ADDR="${OPT_PUBLIC_ADDR:-}"
  copy_options_to_state

  case "$ROLE" in
    portal) wizard_portal ;;
    vector) wizard_vector ;;
    egress) wizard_egress ;;
    *) die err_unknown_cmd "$ROLE" ;;
  esac

  if instance_exists "$NAME"; then
    if [ "$OPT_YES" = 1 ] || ! have_tty; then :; else
      confirm overwrite n "$NAME" || { say cancelled; return 0; }
    fi
  fi

  validate_state
  build_url
  info configuring "$NAME"
  save_instance

  if systemd_available; then
    systemctl daemon-reload
    svc enable "$NAME" >/dev/null 2>&1 || true
    if svc restart "$NAME" >/dev/null 2>&1; then
      ok service_started "$NAME"
    else
      warn service_failed "$NAME"
    fi
  else
    warn no_systemd "$NAME"
  fi

  print_summary
  say wizard_done
}

print_summary() {
  local key_show; key_show="$(redact_key "$KEY")"
  printf '\n%s=== %s ===%s\n' "$C_BOLD" "$(t banner | head -n1)" "$C_RESET"
  printf '  %-10s %s\n' "$(t sum_role):" "$ROLE"
  local state; state="$(svc_state "$NAME")"
  printf '  %-10s %s\n' "$(t sum_service):" "nowhere-${NAME} (${state:-inactive})"
  printf '  %-10s %s\n' "$(t sum_version):" "${VERSION:-unknown}"
  printf '  %-10s %s\n' "$(t sum_config):" "$(instance_dir "$NAME")"
  printf '  %-10s %s\n' "$(t sum_url):" "${URL//$KEY/$key_show}"
  printf '\n%s%s%s\n' "$C_CYAN" "$(t sum_links):" "$C_RESET"
  print_links "$NAME"
  print_firewall_hint
}

print_links() {
  local name="$1" pub="" pin="" share="" vec=""
  load_instance "$name"
  pub="$PUBLIC_ADDR"
  if [ -z "$pub" ]; then
    pub="$(detect_public_addr || true)"
    if [ -n "$pub" ]; then info public_detected "$pub"; else warn public_failed; fi
  fi
  case "$ROLE" in
    portal)
      pin="$(fetch_fingerprint 127.0.0.1 "$PORT" "$KEY" "$MORPH" || true)"
      share="nowhere://${KEY}@$(bracket_host "$pub"):${PORT}?morph=${MORPH}"
      printf '  %s\n' "$share"
      printf '    %s\n' "$(t link_share_hint)"
      if [ -n "$pin" ]; then
        vec="vector://${KEY}@$(bracket_host "$pub"):${PORT}?in=127.0.0.1:1080&morph=${MORPH}&pin=${pin}"
      else
        vec="vector://${KEY}@$(bracket_host "$pub"):${PORT}?in=127.0.0.1:1080&morph=${MORPH}"
      fi
      printf '  %s\n' "$vec"
      printf '    %s\n' "$(t link_vector_hint)"
      ;;
    vector)
      printf '  %s\n' "$URL"
      printf '    %s\n' "$(t link_vector_hint)"
      ;;
    egress)
      printf '  %s\n' "$URL"
      printf '    %s\n' "$(t link_egress_hint)"
      ;;
  esac
  if have qrencode && [ -n "${share:-}" ]; then
    printf '\n'
    qrencode -t ANSIUTF8 "$share" 2>/dev/null || qrencode -t UTF8 "$share" 2>/dev/null || true
  elif ! have qrencode; then
    warn qr_missing
  fi
}

print_firewall_hint() {
  local name="${1:-}" ports=""
  [ -n "${name:-}" ] && load_instance "$name"
  if [ "$ROLE" = portal ]; then
    if have ufw; then
      say fw_ufw "$PORT" "$PORT"
      if [ "${OPT_OPEN_FW:-0}" = 1 ]; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
        ok fw_opened "ufw"
      fi
    elif have firewall-cmd; then
      say fw_firewalld "$PORT" "$PORT"
      if [ "${OPT_OPEN_FW:-0}" = 1 ]; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok fw_opened "firewalld"
      fi
    else
      say fw_iptables "$PORT"
    fi
    say fw_cloud
  fi
}

cmd_menu() {
  if ! have_tty; then
    cmd_status
    say err_no_instances
    return 0
  fi
  while :; do
    printf '\n%s=== Nowhere (NW3) — %s ===%s\n' "$C_BOLD" "$(t banner | head -n1)" "$C_RESET"
    local names=() n state
    while IFS= read -r n; do names+=("$n"); done < <(list_instances)
    if [ "${#names[@]}" -eq 0 ]; then
      say err_no_instances
    else
      printf '%-16s %-8s %-10s %s\n' "$(t inst_header)" "$(t inst_role)" "$(t inst_state)" "$(t inst_url)"
      for n in "${names[@]}"; do
        load_instance "$n"
        state="$(svc_state "$n")"
        printf '%-16s %-8s %-10s %s\n' "$n" "$ROLE" "${state:-inactive}" "${URL//$KEY/$(redact_key "$KEY")}"
      done
    fi
    printf '\n 1) %s\n' "$(t inst_state): nowhere status"
    printf ' 2) %s\n' "start / stop / restart"
    printf ' 3) %s\n' "logs"
    printf ' 4) %s\n' "$(t sum_links) (link)"
    printf ' 5) %s\n' "install / reconfigure (wizard)"
    printf ' 6) %s\n' "pin / probe"
    printf ' 7) %s\n' "update"
    printf ' 8) %s\n' "uninstall"
    printf ' 9) %s\n' "lang / language"
    printf ' 0) %s\n\n' "quit / exit"
    local choice=""
    ask choice confirm_default ""
    case "$choice" in
      1) cmd_status ;;
      2)
        local act="" tgt=""
        ask act svc_action_prompt restart
        ask tgt inst_header --all
        if [ "$tgt" = "--all" ] || [ -z "$tgt" ]; then
          while IFS= read -r n; do svc "$act" "$n" >/dev/null 2>&1 || true; done < <(list_instances)
        else
          svc "$act" "$tgt" >/dev/null 2>&1 || true
        fi
        ;;
      3)
        local tgt=""
        ask tgt inst_header ""
        [ -n "$tgt" ] && cmd_logs "$tgt"
        ;;
      4) cmd_link ;;
      5) cmd_install ;;
      6)
        local tgt=""
        ask tgt inst_header ""
        if [ -n "$tgt" ]; then cmd_pin "$tgt"; fi
        ;;
      7) cmd_update ;;
      8) cmd_uninstall --all ;;
      9) cmd_lang ;;
      0|q|Q|"") break ;;
      *) warn err_unknown_cmd "$choice" ;;
    esac
    printf '\n'
    ask choice confirm_default ""
  done
}

cmd_list() {
  local n found=0
  printf '%-16s %-8s %-10s %s\n' "$(t inst_header)" "$(t inst_role)" "$(t inst_state)" "$(t inst_url)"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    found=1
    load_instance "$n"
    printf '%-16s %-8s %-10s %s\n' "$n" "$ROLE" "$(svc_state "$n")" "${URL//$KEY/$(redact_key "$KEY")}"
  done < <(list_instances)
  [ "$found" = 1 ] || say err_no_instances
  return 0
}

cmd_status() {
  local n found=0
  printf '%-16s %-8s %-10s %s\n' "$(t inst_header)" "$(t inst_role)" "$(t inst_state)" "$(t inst_url)"
  local only="${1:-}"
  if [ -n "$only" ]; then
    instance_exists "$only" || die err_no_instance "$only"
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -n "$only" ] && [ "$n" != "$only" ]; then continue; fi
    found=1
    load_instance "$n"
    printf '%-16s %-8s %-10s %s\n' "$n" "$ROLE" "$(svc_state "$n")" "${URL//$KEY/$(redact_key "$KEY")}"
  done < <(list_instances)
  [ "$found" = 1 ] || { say err_no_instances; return 0; }
  printf '\n%s\n' "$(t stats_title)"
  if [ -x "$NOWHERE_BIN" ]; then
    "$NOWHERE_BIN" status 2>&1 | head -n 40 || warn stats_failed
  else
    warn err_no_instances
  fi
}

svc_action() { # svc_action <action> <name|--all>
  local action="$1" target="${2:-}" n
  [ "$OPT_ALL" = 1 ] && target="--all"
  if [ -z "$target" ] || [ "$target" = "--all" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      instance_exists "$n" || continue
      if systemd_available; then svc "$action" "$n" || warn service_failed "$n"; else warn no_systemd "$n"; fi
    done < <(list_instances)
  else
    instance_exists "$target" || die err_no_instance "$target"
    if systemd_available; then svc "$action" "$target"; else warn no_systemd "$target"; fi
  fi
}

cmd_logs() {
  local name="${1:-}" lines="${OPT_LINES:-100}"
  [ -n "$name" ] || die need_instance_arg
  instance_exists "$name" || die err_no_instance "$name"
  say logs_hint "$name"
  if [ "${OPT_FOLLOW:-0}" = 1 ]; then
    journalctl -u "nowhere-${name}.service" -f -n "$lines"
  else
    journalctl -u "nowhere-${name}.service" -n "$lines" --no-pager
  fi
}

cmd_link() {
  local n found=0
  if [ -n "${1:-}" ]; then
    instance_exists "$1" || die err_no_instance "$1"
    print_links "$1"
    return 0
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    found=1
    printf '\n%s[%s]%s\n' "$C_BOLD" "$n" "$C_RESET"
    print_links "$n"
  done < <(list_instances)
  [ "$found" = 1 ] || say err_no_instances
  return 0
}

cmd_key() {
  local k
  k="$(generate_key)"
  printf '%s\n' "$k"
}

cmd_pin() {
  local name="${1:-}" apply="${OPT_APPLY:-0}"
  [ -n "$name" ] || die need_instance_arg
  instance_exists "$name" || die err_no_instance "$name"
  load_instance "$name"
  local host="" port="" morph="$MORPH" hex=""
  case "$ROLE" in
    portal) host="127.0.0.1"; port="$PORT" ;;
    vector|egress) host="$PORTAL_HOST"; port="$PORTAL_PORT" ;;
  esac
  hex="$(fetch_fingerprint "$host" "$port" "$KEY" "$morph" || true)"
  [ -n "$hex" ] || die pin_failed "${host}:${port}"
  ok pin_fetched "$hex"
  if [ "$apply" = 1 ]; then
    if [ "$ROLE" = portal ]; then
      warn pin_portal_note
      return 0
    fi
    PIN="$hex"
    build_url
    printf '%s\n' "$URL" >"$(instance_url_file "$NAME")"
    chmod 0640 "$(instance_url_file "$NAME")"
    save_instance
    if systemd_available; then svc restart "$NAME" >/dev/null 2>&1 || true; fi
    ok pin_applied "$NAME"
  fi
}

cmd_probe() {
  local url="" target=""
  case "${1:-}" in
    vector://*|portal://*|egress://*|nowhere://*)
      url="$1"; target="${2:-}"
      ;;
    "")
      die probe_usage ;;
    *)
      instance_exists "$1" || die err_no_instance "$1"
      load_instance "$1"
      if [ "$ROLE" = vector ]; then
        url="$URL"
      else
        # probe always dials through a Vector URL; synthesize one
        local h="" p=""
        if [ "$ROLE" = portal ]; then h="127.0.0.1"; p="$PORT"; else h="$PORTAL_HOST"; p="$PORTAL_PORT"; fi
        url="vector://${KEY}@${h}:${p}?morph=${MORPH}"
        [ -n "$PIN" ] && url="${url}&pin=${PIN}"
      fi
      target="${2:-}"
      ;;
  esac
  [ -n "$target" ] || die probe_usage
  case "$target" in
    *:[0-9]*) ;;
    *) die err_target "$target" ;;
  esac
  info probe_running "$target"
  "$NOWHERE_BIN" probe "$url" "$target" 2>&1 || true
}

cmd_update() {
  require_root "$@"
  local only_self=0 only_bin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --self) only_self=1 ;;
      --binary|--binary-only) only_bin=1 ;;
      *) die err_unknown_arg "$1" ;;
    esac
    shift || true
  done
  if [ "$only_bin" != 1 ]; then
    info update_self
    if [ -x "$NW_BIN" ] || [ -w "$BIN_DIR" ]; then
      if curl -fsSL --connect-timeout 10 --retry 2 -A "$CURL_UA" \
           -o "${NW_BIN}.new" "${REPO_RAW_BASE}/${REPO_REF}/nw.sh" 2>/dev/null \
         && bash -n "${NW_BIN}.new" 2>/dev/null; then
        chmod 0755 "${NW_BIN}.new"
        mv -f "${NW_BIN}.new" "$NW_BIN"
        ok update_self_ok
      else
        rm -f "${NW_BIN}.new" 2>/dev/null || true
        warn update_self_skip
      fi
    else
      warn update_self_skip
    fi
  fi
  if [ "$only_self" = 1 ]; then return 0; fi
  install_binary
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    instance_exists "$n" || continue
    info restarting "$n"
    load_instance "$n"
    VERSION="${REL_TAG:-$VERSION}"
    save_instance
    if systemd_available; then svc restart "$n" >/dev/null 2>&1 || warn service_failed "$n"; fi
  done < <(list_instances)
  ok update_done "${REL_TAG:-${OPT_VERSION:-latest}}"
}

cmd_uninstall() {
  require_root "$@"
  local target="" keep_bin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) target="--all" ;;
      --keep-binary) keep_bin=1 ;;
      -*) die err_unknown_arg "$1" ;;
      *) target="$1" ;;
    esac
    shift || true
  done
  local names=() n
  if [ "$target" = "--all" ] || [ -z "$target" ]; then
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(list_instances)
    if [ "${#names[@]}" -eq 0 ]; then say err_no_instances; return 0; fi
    if [ "$OPT_YES" != 1 ] && have_tty; then
      confirm uninstall_ask n "${names[*]}" || return 0
    fi
  else
    instance_exists "$target" || die err_no_instance "$target"
    names=("$target")
    if [ "$OPT_YES" != 1 ] && have_tty; then
      confirm uninstall_ask n "$target" || return 0
    fi
  fi
  for n in "${names[@]}"; do
    if systemd_available; then
      svc stop "$n" >/dev/null 2>&1 || true
      svc disable "$n" >/dev/null 2>&1 || true
      rm -f "$(instance_unit "$n")"
    fi
    rm -f "$(instance_wrapper "$n")"
    rm -rf "$(instance_dir "$n")"
    ok uninstall_done "$n"
  done
  if systemd_available; then systemctl daemon-reload || true; fi
  if [ "${#names[@]}" -gt 0 ] && [ -z "$(list_instances)" ]; then
    say uninstall_all_done
    if [ "$keep_bin" != 1 ]; then
      if [ "$OPT_YES" = 1 ] || ! have_tty || confirm uninstall_bin y; then
        rm -f "$NOWHERE_BIN"
        ok uninstall_bin_done "$NOWHERE_BIN"
      fi
    fi
  fi
}

cmd_run() {
  local name="${1:-}"
  [ -n "$name" ] || die need_instance_arg
  instance_exists "$name" || die err_no_instance "$name"
  say run_hint "$name"
  exec "$(instance_wrapper "$name")"
}

cmd_version() {
  say version_line "$NW_VERSION" "$(installed_version)"
}

cmd_lang() {
  local want="${1:-}"
  if [ -z "$want" ] && have_tty; then
    local l=""
    choose l lang_prompt zh zh en
    want="$l"
  fi
  case "$want" in
    zh|zh_CN|zh-CN) NW_LANG_CODE=zh ;;
    en|EN) NW_LANG_CODE=en ;;
    *) die err_unknown_arg "lang=${want:-<empty>}" ;;
  esac
  if [ -d "$ETC_DIR" ] && [ -w "$ETC_DIR" ]; then
    printf '%s\n' "$NW_LANG_CODE" >"$LANG_FILE" 2>/dev/null || true
  fi
  say lang_saved
}

cmd_help() {
  cat <<'EOF'
Nowhere (NW3) one-click installer & manager — Nowhere (NW3) 一键安装与管理脚本

Usage / 用法:
  nw.sh [command] [options]

Commands / 命令:
  (none) | install | wizard   Interactive install wizard / 交互式安装向导
  portal | vector | egress    Install one role directly / 直接安装指定角色
  menu                        Interactive management menu / 交互式管理菜单
  list                        List instances / 列出实例
  status [name]               Service + traffic status / 服务与流量状态
  start|stop|restart [name|--all]
  enable|disable [name|--all] Service lifecycle / 服务生命周期
  logs <name> [-f] [-n N]     Journal logs / 系统日志
  link [name]                 Client links + QR / 客户端链接与二维码
  key                         Generate a shared key / 生成共享密钥
  pin <name> [--apply]        Fetch certificate fingerprint / 获取证书指纹
  probe <name|url> <host:port>  Test a real TCP Flow / 测试真实 TCP Flow
  update [--self|--binary]    Update script and binary / 更新脚本与二进制
  uninstall [name|--all]      Remove instances / 卸载实例
  run <name>                  Run in foreground / 前台运行
  version                     Show versions / 显示版本
  lang [zh|en]                UI language / 界面语言
  help                        This help / 本帮助

Install options / 安装选项:
  --role ROLE           portal|vector|egress
  --name NAME           Instance name, service becomes nowhere-<name> / 实例名
  --key HEX             32 hex shared key / 32 位十六进制共享密钥
  --port PORT           Portal listen port (default 2000)
  --tcp-port PORT       Separate TCP (TLS) port / 独立 TCP 端口
  --udp-port PORT       Separate UDP (QUIC) port / 独立 UDP 端口
  --carrier MODE        same|split|tcp|udp  Portal carrier layout / 载体布局
  --out MODE            direct|socks|egress  Portal exit / Portal 出口
  --socks ADDR          [user:pass@]host:port SOCKS5 upstream / SOCKS5 上游
  --portal-host HOST    Portal address for vector/egress / Portal 地址
  --portal-port PORT    Portal port for vector/egress (default 2000)
  --net tcp|udp         Vector carrier (default tcp) / Vector 载体
  --in ADDR             Vector SOCKS5 listen (default 127.0.0.1:1080)
  --in-auth USER:PASS   SOCKS5 authentication / SOCKS5 认证
  --pin HEX64           Certificate pin / 证书 pin
  --morph 0|1           Wire masking, default 1 / 线路伪装，默认 1
  --tls 1|2             Self-signed (1) or PEM files (2) / 证书模式
  --crt PATH --key PATH PEM chain / private key / PEM 证书链与私钥
  --rate N --etar N     Mbps limits, 0 = off / 限速
  --public-addr ADDR    Public address used in links / 链接中的对外地址
  --version TAG         Install a release, e.g. v3.0.1 / 指定发行版本
  --open-firewall       Auto-allow ports (ufw/firewalld) / 自动放行防火墙
  --yes                 Non-interactive defaults / 非交互默认值
  --lang zh|en          UI language / 界面语言

Environment / 环境变量:
  NW_REF=main            script source ref / 脚本来源分支
  NW_RAW_BASE=URL        script source base (mirror friendly) / 脚本源(可用镜像)
  NW_PREFIX=/usr/local   binary prefix / 二进制前缀
  NW_ETC=/etc/nowhere     config root / 配置根目录
  NW_VERSION=v3.0.1      pin upstream release / 固定上游版本
  NW_LOCAL_TARBALL=PATH  install from a local archive / 本地归档安装
  NW_SKIP_VERIFY=1       skip SHA-256 check / 跳过校验
  NW_LANG=zh|en          UI language / 界面语言

Docs / 文档: https://github.com/NodePassProject/Nowhere/blob/main/docs/README.md
EOF
}

# ============================== argument parsing ============================
CMD=""
OPT_ROLE=""; OPT_NAME=""; OPT_KEY=""; OPT_MORPH=""; OPT_PORT=""
OPT_TCP_PORT=""; OPT_UDP_PORT=""; OPT_TCP_CARRIER=""; OPT_UDP_CARRIER=""; OPT_CARRIER=""
OPT_OUT=""; OPT_SOCKS=""; OPT_PORTAL_HOST=""; OPT_PORTAL_PORT=""; OPT_NET=""
OPT_IN=""; OPT_IN_AUTH=""; OPT_PIN=""; OPT_SNI=""; OPT_RATE=""; OPT_ETAR=""
OPT_TLS=""; OPT_CRT=""; OPT_KEY_PATH=""; OPT_PUBLIC_ADDR=""; OPT_VERSION=""
OPT_YES=0; OPT_FORCE=0; OPT_OPEN_FW=0; OPT_FOLLOW=0; OPT_ALL=0; OPT_LINES=100; OPT_APPLY=0

usage_error() { die err_unknown_cmd "${1:-}"; }

parse_args() {
  CMD="${1:-}"
  [ $# -gt 0 ] && shift
  case "$CMD" in
    ""|install|wizard) CMD=install ;;
    --version|-V) CMD=version ;;
    -h|--help) CMD=help ;;
    -*) CMD=install ;;   # options first (e.g. --yes) → interactive wizard
    portal|vector|egress)
      OPT_ROLE="$CMD"; CMD=install ;;
    menu) CMD=menu ;;
    list|ls) CMD=list ;;
    status) CMD=status ;;
    start|stop|restart|enable|disable) CMD="svc:$CMD" ;;
    logs|log) CMD=logs ;;
    link|links) CMD=link ;;
    key|gen-key) CMD=key ;;
    pin|fingerprint) CMD=pin ;;
    probe) CMD=probe ;;
    update|upgrade) CMD=update ;;
    uninstall|remove) CMD=uninstall ;;
    run|fg) CMD=run ;;
    version|--version|-V) CMD=version ;;
    lang|language) CMD=lang ;;
    help|-h|--help) CMD=help ;;
    *) usage_error "$CMD" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) OPT_ROLE="${2:-}"; shift 2 ;;
      --role=*) OPT_ROLE="${1#*=}"; shift ;;
      --name) OPT_NAME="${2:-}"; shift 2 ;;
      --name=*) OPT_NAME="${1#*=}"; shift ;;
      --key) OPT_KEY="${2:-}"; shift 2 ;;
      --key=*) OPT_KEY="${1#*=}"; shift ;;
      --port) OPT_PORT="${2:-}"; shift 2 ;;
      --port=*) OPT_PORT="${1#*=}"; shift ;;
      --tcp-port) OPT_TCP_PORT="${2:-}"; shift 2 ;;
      --udp-port) OPT_UDP_PORT="${2:-}"; shift 2 ;;
      --tcp-carrier) OPT_TCP_CARRIER="${2:-}"; shift 2 ;;
      --udp-carrier) OPT_UDP_CARRIER="${2:-}"; shift 2 ;;
      --carrier) OPT_CARRIER="${2:-}"; shift 2 ;;
      --carrier=*) OPT_CARRIER="${1#*=}"; shift ;;
      --out) OPT_OUT="${2:-}"; shift 2 ;;
      --out=*) OPT_OUT="${1#*=}"; shift ;;
      --socks) OPT_SOCKS="${2:-}"; shift 2 ;;
      --socks=*) OPT_SOCKS="${1#*=}"; shift ;;
      --portal-host) OPT_PORTAL_HOST="${2:-}"; shift 2 ;;
      --portal-host=*) OPT_PORTAL_HOST="${1#*=}"; shift ;;
      --portal-port) OPT_PORTAL_PORT="${2:-}"; shift 2 ;;
      --portal-port=*) OPT_PORTAL_PORT="${1#*=}"; shift ;;
      --net) OPT_NET="${2:-}"; shift 2 ;;
      --net=*) OPT_NET="${1#*=}"; shift ;;
      --in) OPT_IN="${2:-}"; shift 2 ;;
      --in=*) OPT_IN="${1#*=}"; shift ;;
      --in-auth) OPT_IN_AUTH="${2:-}"; shift 2 ;;
      --in-auth=*) OPT_IN_AUTH="${1#*=}"; shift ;;
      --pin) OPT_PIN="${2:-}"; shift 2 ;;
      --pin=*) OPT_PIN="${1#*=}"; shift ;;
      --sni) OPT_SNI="${2:-}"; shift 2 ;;
      --sni=*) OPT_SNI="${1#*=}"; shift ;;
      --morph) OPT_MORPH="${2:-}"; shift 2 ;;
      --morph=*) OPT_MORPH="${1#*=}"; shift ;;
      --rate) OPT_RATE="${2:-}"; shift 2 ;;
      --rate=*) OPT_RATE="${1#*=}"; shift ;;
      --etar) OPT_ETAR="${2:-}"; shift 2 ;;
      --etar=*) OPT_ETAR="${1#*=}"; shift ;;
      --tls) OPT_TLS="${2:-}"; shift 2 ;;
      --tls=*) OPT_TLS="${1#*=}"; shift ;;
      --crt) OPT_CRT="${2:-}"; shift 2 ;;
      --crt=*) OPT_CRT="${1#*=}"; shift ;;
      --key-path) OPT_KEY_PATH="${2:-}"; shift 2 ;;
      --key-path=*) OPT_KEY_PATH="${1#*=}"; shift ;;
      --public-addr) OPT_PUBLIC_ADDR="${2:-}"; shift 2 ;;
      --public-addr=*) OPT_PUBLIC_ADDR="${1#*=}"; shift ;;
      --version) OPT_VERSION="${2:-}"; shift 2 ;;
      --version=*) OPT_VERSION="${1#*=}"; shift ;;
      --yes|-y) OPT_YES=1; shift ;;
      --force) OPT_FORCE=1; shift ;;
      --all|-a) OPT_ALL=1; shift ;;
      --apply) OPT_APPLY=1; shift ;;
      --open-firewall) OPT_OPEN_FW=1; shift ;;
      --follow|-f) OPT_FOLLOW=1; shift ;;
      -n|--lines) OPT_LINES="${2:-100}"; shift 2 ;;
      -n=*) OPT_LINES="${1#*=}"; shift ;;
      --lang) NW_LANG="${2:-}"; resolve_lang; shift 2 ;;
      --lang=*) NW_LANG="${1#*=}"; resolve_lang; shift ;;
      --) shift; break ;;
      -*) die err_unknown_arg "$1" ;;
      *) EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
  while [ $# -gt 0 ]; do EXTRA_ARGS+=("$1"); shift; done
}

EXTRA_ARGS=()

main() {
  resolve_lang
  parse_args "$@"
  case "$CMD" in
    install) cmd_install "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    menu)    cmd_menu ;;
    list)    cmd_list ;;
    status)  cmd_status "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    svc:*)   svc_action "${CMD#svc:}" "${EXTRA_ARGS[0]:-}" ;;
    logs)    cmd_logs "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    link)    cmd_link "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    key)     cmd_key ;;
    pin)     cmd_pin "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    probe)   cmd_probe "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    update)  cmd_update "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    uninstall) cmd_uninstall "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
    run)     cmd_run "${EXTRA_ARGS[0]:-}" ;;
    version) cmd_version ;;
    lang)    cmd_lang "${EXTRA_ARGS[0]:-}" ;;
    help)    cmd_help ;;
    *) usage_error "$CMD" ;;
  esac
}

# Allow sourcing for tests: NW_LIB_ONLY=1 bash -c 'source nw.sh; ...'
if [ "${NW_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
