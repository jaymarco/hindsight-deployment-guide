# 脚本目录

本目录包含 Hindsight + Hermes Agent 部署所需的脱敏脚本。所有脚本中的 `{{PLACEHOLDER}}` 需替换为实际值后使用。

## 脚本清单

| 脚本 | 用途 | 部署位置 |
|---|---|---|
| `start-hindsight.sh` | 启动 Hindsight 容器（带固定 IP）| `/opt/hermes-memory-installer/start-hindsight.sh` |
| `healthcheck.sh` | 5 profile + Hindsight 健康检查 | `/opt/hermes-memory-installer/healthcheck.sh` |
| `backup.sh` | Hindsight 数据卷 + 配置每日备份 | `/opt/hermes-memory-installer/backup.sh` |
| `hindsight-webui.conf` | httpd 反代配置（WebUI 入口）| `/etc/httpd/conf.d/hindsight-webui.conf` |
| `iptables-rules.txt` | iptables 规则模板 | `/etc/sysconfig/iptables` |
| `hindsight-config.json` | Hindsight 客户端配置 | `/home/aiagent/.hermes/hindsight/config.json` |
| `profile-env-template.env` | 5 profile .env 模板 | `/home/aiagent/.hermes/profiles/<p>/.env` |
| `profile-config-snippet.yaml` | 5 profile config.yaml 片段 | 合并到 `/home/aiagent/.hermes/profiles/<p>/config.yaml` |

## 占位符清单

| 占位符 | 含义 |
|---|---|
| `{{PROD_HOST_IP}}` | 生产机 IP |
| `{{HINDSIGHT_CONTAINER_IP}}` | Hindsight 容器固定 IP |
| `{{INTRANET_CIDR}}` | 内网网段 |
| `{{USER_LAPTOP_IP}}` | 用户电脑 IP |
| `{{NEWAPI_KEY}}` | LLM 网关 API key |
| `{{INTERNAL_KEY}}` | Hindsight 内部 API key |
| `{{ARCHITECT_BOT_KEY}}` 等 | 各 profile API key |
| `{{LLM_MODEL}}` | 主力 LLM 模型名 |
| `{{EMBED_MODEL}}` | Embedding 模型名 |
| `{{BACKUP_ROOT}}` | 备份根目录 |

## 使用方法

1. 复制需要的脚本到目标位置
2. 全文替换 `{{PLACEHOLDER}}` 为实际值
3. 赋予执行权限: `chmod +x *.sh`
4. 执行: `./start-hindsight.sh`

```bash
# 一键替换占位符（在你所有值都准备好时）
# 提示：把 <你的实际值> 替换为真实值（IP/网段/密钥/路径/模型名等）
cd scripts/
for f in *; do
  sed -i "s|{{PROD_HOST_IP}}|<你的生产机IP>|g; \
          s|{{HINDSIGHT_CONTAINER_IP}}|<你的容器IP>|g; \
          s|{{INTRANET_CIDR}}|<你的内网网段>|g; \
          s|{{USER_LAPTOP_IP}}|<你的电脑IP>|g" "$f"
done
```
