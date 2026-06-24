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

# CF API 调用函数
# 参数: method path [json_body]
# 返回: 原始 JSON 响应到 stdout，HTTP 错误时 stderr 报错并返回 1
cf_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=(-s -w "\n%{http_code}" -X "$method"
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json"
    "${CF_API_BASE}${path}")
  [[ -n "$body" ]] && args+=(-d "$body")

  local response http_code
  response=$(curl "${args[@]}") || { log_err "curl 请求失败"; return 1; }
  http_code=$(tail -n1 <<< "$response")
  response=$(head -n -1 <<< "$response")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    local err_msg
    err_msg=$(jq -r '.errors[0].message // "未知错误"' <<< "$response" 2>/dev/null) || err_msg="无效响应体"
    log_err "HTTP $http_code：${err_msg}"
    return 1
  fi
  echo "$response"
  return 0
}

# 检查 CF API 响应的 success 字段
# 参数: json
# 返回: 失败时打印错误信息并返回 1
cf_check_success() {
  local json="$1"
  if [[ "$(jq -r '.success' <<< "$json")" != "true" ]]; then
    local msg
    msg=$(jq -r '.errors[0].message // "未知错误"' <<< "$json")
    log_err "API 返回失败：$msg"
    return 1
  fi
  return 0
}
