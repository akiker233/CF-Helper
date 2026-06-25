#!/usr/bin/env bash
# 一键启动脚本，从 ~/.cf-helper.conf 加载凭证后运行 cf-helper.sh

CONF_FILE="$HOME/.cf-helper.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 首次运行时引导创建配置文件
if [[ ! -f "$CONF_FILE" ]]; then
  echo "=== CF-Helper 首次配置 ==="
  echo ""
  echo "选择认证方式："
  echo "  [1] API Token（推荐）"
  echo "  [2] Global API Key"
  echo ""
  read -rp "选择（1/2）: " auth_choice

  case "$auth_choice" in
    1)
      read -rp "请输入 CF_API_TOKEN: " token
      echo "CF_API_TOKEN=\"$token\"" > "$CONF_FILE"
      ;;
    2)
      read -rp "请输入 CF_API_EMAIL: " email
      read -rp "请输入 CF_API_KEY: " key
      {
        echo "CF_API_EMAIL=\"$email\""
        echo "CF_API_KEY=\"$key\""
      } > "$CONF_FILE"
      ;;
    *)
      echo "无效选择，退出。"
      exit 1
      ;;
  esac

  chmod 600 "$CONF_FILE"
  echo ""
  echo "配置已保存到 $CONF_FILE"
  echo ""
fi

# 加载配置
# shellcheck source=/dev/null
source "$CONF_FILE"

# 运行主脚本，透传所有参数
exec "$SCRIPT_DIR/cf-helper.sh" "$@"
