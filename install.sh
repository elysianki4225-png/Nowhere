#!/usr/bin/env bash
#
# install.sh — Nowhere (NW3) one-click bootstrap
#              一键安装入口（下载并执行 nw.sh）
#
# One-liner / 一键命令:
#   curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash
#
# With arguments / 带参数:
#   curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash -s -- portal --yes
#
# The real installer + manager lives in nw.sh; this file only fetches it.
# 真正的安装与管理逻辑在 nw.sh 中，本文件负责获取并执行它。
#
set -euo pipefail

REPO_SLUG="${NW_REPO_SLUG:-elysianki4225-png/Nowhere}"
REPO_REF="${NW_REF:-main}"
REPO_RAW_BASE="${NW_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}}"
NW_URL="${REPO_RAW_BASE}/${REPO_REF}/nw.sh"
UA="install.sh (+https://github.com/${REPO_SLUG})"

log() { printf '%s\n' "$*" >&2; }

# 1) Running from a git checkout? Prefer the sibling nw.sh.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "${SELF_DIR:-}" ] && [ -f "${SELF_DIR}/nw.sh" ]; then
  exec bash "${SELF_DIR}/nw.sh" "$@"
fi

# 2) Already installed? Just run the installed manager (nw update refreshes it).
if [ "${NW_FORCE_DOWNLOAD:-0}" != 1 ] && [ -x /usr/local/bin/nw ]; then
  exec /usr/local/bin/nw "$@"
fi

# 3) Download nw.sh to a temp file, then run it (keeps stdin free for prompts).
TMP="$(mktemp /tmp/nw.sh.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
log "==> Fetching ${NW_URL}"
if ! curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 -A "$UA" -o "$TMP" "$NW_URL"; then
  log "!! Failed to download nw.sh from ${NW_URL}"
  log "!! If raw.githubusercontent.com is unreachable, set NW_RAW_BASE to a mirror, e.g.:"
  log "!!   NW_RAW_BASE=https://ghproxy.net/https://raw.githubusercontent.com/${REPO_SLUG}"
  exit 1
fi
bash -n "$TMP" || { log "!! Downloaded script failed syntax check"; exit 1; }

# 4) Re-exec as root when needed (sudo preserves the caller's environment).
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$TMP" "$@"
  fi
  log "!! This installer must run as root; sudo was not found."
  exit 1
fi

exec bash "$TMP" "$@"
