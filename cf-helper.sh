#!/usr/bin/env bash
set -euo pipefail

CF_API_BASE="https://api.cloudflare.com/client/v4"

# 颜色支持检测
if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' NC=''
fi

# 日志函数
log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 依赖检查函数
check_deps() {
  local missing=0
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_err "缺少依赖：$cmd"
      case "$cmd" in
        jq)   log_err "  安装：apt install jq  /  brew install jq  /  yum install jq" ;;
        curl) log_err "  安装：apt install curl  /  brew install curl" ;;
      esac
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

# 凭证检查函数
check_token() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    log_err "未找到 CF_API_TOKEN，请先执行："
    log_err "  export CF_API_TOKEN=\"your_api_token\""
    exit 1
  fi
}
