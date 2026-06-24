# CF-Helper 设计文档

**日期：** 2026-06-25  
**状态：** 已确认

---

## 概述

单文件 bash 脚本 `cf-helper.sh`，通过 Cloudflare API 管理账号下的域名安全/开发模式。依赖：`curl`、`jq`。

---

## 架构

```
cf-helper.sh
├── 凭证检查        — 验证 CF_API_TOKEN 环境变量
├── API 层          — 封装 curl 调用，统一处理响应和错误
├── 功能模块        — get_zones / set_security_level / set_dev_mode
├── 命令行模式      — 解析 $1 $2，直接执行
└── 交互菜单        — 无参数时展示域名列表 + 操作列表
```

---

## 凭证

从环境变量 `CF_API_TOKEN` 读取（Cloudflare Bearer Token）。  
脚本启动时检查，缺失则报错退出，并打印设置说明：

```
[ERROR] 未找到 CF_API_TOKEN，请先执行：
  export CF_API_TOKEN="your_api_token"
```

---

## 功能模块

| 模块 | API 端点 | 说明 |
|------|----------|------|
| 获取域名列表 | `GET /zones?per_page=50` | 返回所有 zone 的 name + id，自动翻页 |
| 开启 Under Attack | `PATCH /zones/{id}/settings/security_level` | value: `under_attack` |
| 关闭 Under Attack | `PATCH /zones/{id}/settings/security_level` | value: `high` |
| 开启开发模式 | `PATCH /zones/{id}/settings/development_mode` | value: `on` |
| 关闭开发模式 | `PATCH /zones/{id}/settings/development_mode` | value: `off` |

> 关闭 Under Attack 时还原为 `high`（而非 `medium`），因为 `under_attack` 通常在高风险时启用，关闭后应保持较高防护。

---

## 命令行接口

```bash
# 交互菜单
./cf-helper.sh

# 直接执行（适合 CI / cron）
./cf-helper.sh <zone_name|all> <attack-on|attack-off|dev-on|dev-off>

# 示例
./cf-helper.sh example.com attack-on    # 开启 Under Attack
./cf-helper.sh example.com attack-off   # 关闭 Under Attack
./cf-helper.sh example.com dev-on       # 开启开发模式
./cf-helper.sh example.com dev-off      # 关闭开发模式
./cf-helper.sh all attack-on            # 批量开启 Under Attack
```

---

## 交互菜单流程

```
1. 调用 get_zones，列出所有域名并编号
2. 用户输入编号选择域名（或输入 0 选择所有域名）
3. 列出操作：
   [1] 开启 Under Attack 模式
   [2] 关闭 Under Attack 模式
   [3] 开启开发模式（Development Mode）
   [4] 关闭开发模式
4. 执行，输出结果
```

---

## 错误处理

- API 调用失败：输出 HTTP 状态码 + CF 返回的 `errors[].message`，不静默失败
- 批量操作（`all`）：逐个域名执行，某个失败打印错误后继续下一个，最终汇总成功/失败数量
- 域名不存在：找不到匹配的 zone name 时，报错退出

---

## 用户体验

- 颜色输出：检测 `$TERM` 是否支持，降级为纯文本
  - 绿色：成功
  - 红色：失败
  - 黄色：信息/提示
- 操作前打印将要执行的动作
- 操作后打印 API 返回的当前状态值作为确认

---

## 文件结构

```
CF-Helper/
└── cf-helper.sh          # 单文件脚本，chmod +x 后直接使用
```

---

## 依赖

| 工具 | 用途 | 备注 |
|------|------|------|
| `curl` | 调用 CF API | 几乎所有系统标配 |
| `jq` | 解析 JSON 响应 | 大多数服务器已装；缺失时报错提示安装命令 |
