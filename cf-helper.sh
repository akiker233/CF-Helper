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
  local success
  success=$(jq -r '.success' <<< "$json" 2>/dev/null) || { log_err "API 响应解析失败"; return 1; }
  if [[ "$success" != "true" ]]; then
    local msg
    msg=$(jq -r '.errors[0].message // "未知错误"' <<< "$json" 2>/dev/null) || msg="未知错误"
    log_err "API 返回失败：$msg"
    return 1
  fi
  return 0
}

# 获取所有域名列表，支持自动翻页
# 参数: 无
# 返回: 输出 JSON 数组 [{"name":"...","id":"..."},...]，失败返回 1
get_zones() {
  local page=1 all_zones='[]'
  while true; do
    local resp
    resp=$(cf_api GET "/zones?per_page=50&page=${page}") || return 1
    cf_check_success "$resp" || return 1

    local zones total_pages
    zones=$(jq '[.result[] | {name: .name, id: .id}]' <<< "$resp")
    total_pages=$(jq -r '.result_info.total_pages' <<< "$resp")
    all_zones=$(jq -s '.[0] + .[1]' <(echo "$all_zones") <(echo "$zones"))

    [[ "$page" -ge "$total_pages" ]] && break
    ((page++))
  done
  echo "$all_zones"
}

# 根据域名从 zones JSON 中查询 zone_id
# 参数: zone_name zones_json
# 返回: 输出 zone_id，未找到返回 1
get_zone_id() {
  local zone_name="$1" zones="$2"
  local zone_id
  zone_id=$(jq -r --arg name "$zone_name" '.[] | select(.name == $name) | .id' <<< "$zones")
  if [[ -z "$zone_id" ]]; then
    log_err "未找到域名：$zone_name"
    return 1
  fi
  echo "$zone_id"
}

# 设置域名的安全级别
# 参数: zone_id zone_name under_attack|high
# 返回: 成功输出结果，失败返回 1
set_security_level() {
  local zone_id="$1" zone_name="$2" value="$3"
  local label
  [[ "$value" == "under_attack" ]] && label="Under Attack 模式" || label="高防护模式(high)"
  log_info "正在对 ${zone_name} 设置安全级别 → ${label}..."
  local resp
  resp=$(cf_api PATCH "/zones/${zone_id}/settings/security_level" \
    "{\"value\":\"${value}\"}") || return 1
  cf_check_success "$resp" || return 1
  local current
  current=$(jq -r '.result.value' <<< "$resp")
  log_ok "${zone_name} 安全级别已设为：${current}"
}

# 设置域名的开发模式
# 参数: zone_id zone_name on|off
# 返回: 成功输出结果，失败返回 1
set_dev_mode() {
  local zone_id="$1" zone_name="$2" value="$3"
  local label
  [[ "$value" == "on" ]] && label="开启" || label="关闭"
  log_info "正在对 ${zone_name} ${label}开发模式..."
  local resp
  resp=$(cf_api PATCH "/zones/${zone_id}/settings/development_mode" \
    "{\"value\":\"${value}\"}") || return 1
  cf_check_success "$resp" || return 1
  local current
  current=$(jq -r '.result.value' <<< "$resp")
  log_ok "${zone_name} 开发模式当前状态：${current}"
}
