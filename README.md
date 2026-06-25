# CF-Helper

通过 Cloudflare API 管理域名安全模式的 bash 脚本，支持一键开启 Under Attack 模式或 Development 模式。

## 依赖

- `curl`
- `jq`

## 认证

支持两种方式（二选一）：

```bash
# 方式一：API Token（推荐）
export CF_API_TOKEN="your_api_token"

# 方式二：Global API Key
export CF_API_EMAIL="your@email.com"
export CF_API_KEY="your_global_api_key"
```

## 用法

```bash
chmod +x cf-helper.sh

# 交互菜单（自动列出所有域名）
./cf-helper.sh

# 命令行直接执行
./cf-helper.sh example.com attack-on    # 开启 Under Attack 模式
./cf-helper.sh example.com attack-off   # 关闭 Under Attack 模式（还原为 high）
./cf-helper.sh example.com dev-on       # 开启开发模式
./cf-helper.sh example.com dev-off      # 关闭开发模式
./cf-helper.sh all attack-on            # 批量操作所有域名
```

## 操作说明

| 操作 | 说明 |
|------|------|
| `attack-on` | 开启 Under Attack 模式（安全级别设为 `under_attack`） |
| `attack-off` | 关闭 Under Attack 模式（安全级别还原为 `high`） |
| `dev-on` | 开启 Development 模式 |
| `dev-off` | 关闭 Development 模式 |
