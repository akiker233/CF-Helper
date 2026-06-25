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

# 批量操作辅助函数
# 参数: target(zone_name|all) action(attack-on|attack-off|dev-on|dev-off) zones_json
# 返回: 单域名失败返回 1；all 时统计结果，有失败返回 1
do_action() {
  local target="$1" action="$2" zones_json="$3"
  local success=0 fail=0

  # 验证 action 参数
  case "$action" in
    attack-on|attack-off|dev-on|dev-off) ;;
    *)
      log_err "未知操作：$action"
      return 1
      ;;
  esac

  # 执行单个域名的操作
  run_one() {
    local zname="$1" zid="$2"
    case "$action" in
      attack-on)  set_security_level "$zid" "$zname" "under_attack" && ((success++)) || ((fail++)) ;;
      attack-off) set_security_level "$zid" "$zname" "high"         && ((success++)) || ((fail++)) ;;
      dev-on)     set_dev_mode       "$zid" "$zname" "on"           && ((success++)) || ((fail++)) ;;
      dev-off)    set_dev_mode       "$zid" "$zname" "off"          && ((success++)) || ((fail++)) ;;
    esac
  }

  if [[ "$target" == "all" ]]; then
    # 批量操作模式：逐个执行，某个失败不中断
    while IFS= read -r zone; do
      local zname zid
      zname=$(jq -r '.name' <<< "$zone")
      zid=$(jq -r '.id'   <<< "$zone")
      run_one "$zname" "$zid"
    done < <(jq -c '.[]' <<< "$zones_json")
    echo ""
    log_info "批量完成：成功 ${success} 个，失败 ${fail} 个"
    [[ $fail -eq 0 ]] || return 1
  else
    # 单域名模式：直接执行，失败返回 1
    local zid
    zid=$(get_zone_id "$target" "$zones_json") || return 1
    run_one "$target" "$zid"
  fi
}

# 交互菜单函数
# 参数: zones_json（域名列表的 JSON 数组）
# 功能: 显示域名列表和操作菜单，让用户交互选择
interactive_menu() {
  local zones_json="$1"
  local zone_names=()
  while IFS= read -r name; do
    zone_names+=("$name")
  done < <(jq -r '.[].name' <<< "$zones_json")

  echo ""
  echo "=== 域名列表 ==="
  echo "  [0] 所有域名"
  local i=1
  for name in "${zone_names[@]}"; do
    printf "  [%d] %s\n" "$i" "$name"
    ((i++))
  done
  echo ""
  read -rp "选择域名（输入编号）: " choice

  local target
  if [[ "$choice" == "0" ]]; then
    target="all"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#zone_names[@]} )); then
    target="${zone_names[$((choice-1))]}"
  else
    log_err "无效选择：$choice"
    exit 1
  fi

  echo ""
  echo "=== 选择操作 ==="
  echo "  [1] 开启 Under Attack 模式"
  echo "  [2] 关闭 Under Attack 模式（还原为 high）"
  echo "  [3] 开启开发模式（Development Mode）"
  echo "  [4] 关闭开发模式"
  echo ""
  read -rp "选择操作（输入编号）: " op_choice

  local action
  case "$op_choice" in
    1) action="attack-on"  ;;
    2) action="attack-off" ;;
    3) action="dev-on"     ;;
    4) action="dev-off"    ;;
    *) log_err "无效操作：$op_choice"; exit 1 ;;
  esac

  echo ""
  do_action "$target" "$action" "$zones_json"
}

# 打印使用说明
usage() {
  cat <<EOF
用法：
  $(basename "$0")                              # 交互菜单
  $(basename "$0") <zone_name|all> <action>     # 直接执行

action 可选值：
  attack-on   开启 Under Attack 模式
  attack-off  关闭 Under Attack 模式（还原为 high）
  dev-on      开启开发模式
  dev-off     关闭开发模式

示例：
  $(basename "$0") example.com attack-on
  $(basename "$0") all dev-off

环境变量：
  CF_API_TOKEN  Cloudflare API Token（必填）
EOF
}

# 脚本主入口
# 无参数时: 交互菜单模式
# 2 个参数时: 命令行直接执行模式
# 其他: 打印 usage 并退出 1
main() {
  check_deps
  check_token

  if [[ $# -eq 0 ]]; then
    log_info "正在获取域名列表..."
    local zones_json
    zones_json=$(get_zones) || exit 1
    local count
    count=$(jq 'length' <<< "$zones_json")
    log_ok "共找到 ${count} 个域名"
    interactive_menu "$zones_json"
  elif [[ $# -eq 2 ]]; then
    local target="$1" action="$2"
    log_info "正在获取域名列表..."
    local zones_json
    zones_json=$(get_zones) || exit 1
    do_action "$target" "$action" "$zones_json"
  else
    usage
    exit 1
  fi
}

main "$@"
