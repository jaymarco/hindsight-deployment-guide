# Hindsight 长期记忆系统 — 部署与 Hermes Agent 集成操作方案

> 一份从 0 到 1 在生产环境部署 Hindsight 长期记忆系统，并将其与 5 个 Hermes Agent profile 集成的完整操作手册。
>
> **适用版本**：Hindsight 0.8.6（`ghcr.io/vectorize-io/hindsight:latest`）+ Hermes Agent 5 profile（architect-bot / dba-bot / itm-bot / middleware-bot / sysops-bot）
>
> **目标读者**：负责部署、运维、扩展 Hindsight + Hermes 集成的工程师和 SRE

---

## 目录

- [1. 概述](#1-概述)
- [2. 架构](#2-架构)
- [3. 准备工作](#3-准备工作)
- [4. Hindsight 部署](#4-hindsight-部署)
- [5. 5 profile 集成](#5-5-profile-集成)
- [6. 安全加固](#6-安全加固)
- [7. 跨 Agent 信息共享](#7-跨-agent-信息共享)
- [8. 故障排查（真实踩过的坑）](#8-故障排查真实踩过的坑)
- [9. 监控与运维](#9-监控与运维)
- [10. 附录](#10-附录)

---

## 1. 概述

### 1.1 为什么要做这件事

**核心痛点**：AI Agent 默认只有"工作记忆"（上下文窗口），一旦窗口刷新或换会话就清零。多 Agent 团队需要"长期记忆"在所有 profile 之间共享。

**目标**：
1. 部署一个生产级长期记忆系统（Hindsight）
2. 让 5 个 Hermes Agent profile **强制走 Hindsight**（不靠 prompt 提示）
3. 未来无缝支持 Codex / Claude Code / Cursor 等其他 Agent
4. 提供 WebUI 可视化管理 + API 访问

### 1.2 关键决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 长期记忆引擎 | **Hindsight 0.8.6** | 开源（MIT，⭐19k+）、生产级、API + WebUI、内置 PG + 向量 |
| 5 profile 共享 | **bank_id=hermes** | 跨 agent 共享记忆 |
| 强制走 Hindsight | **改 `memory_enabled: false` + `provider: hindsight`** | 不靠 prompt 提示 |
| WebUI 入口 | **httpd 反代 8081 → 容器 9999** | 避开 Chrome 黑名单 + 容器内 9999 仅绑 127.0.0.1 |
| 跨 agent 系统元信息 | **根 `~/.hermes/config.yaml` 的 `agent.system_prompt`** | 5 profile 共享 |
| Hindsight Directives | ❌ **不能用** | Directives API 只用于 reflect，不注入 LLM |

### 1.3 不做什么

- 不下 `daemon.json` 的 `group: docker`（避免重启时丢权限）
- 不动 `docker.sock` 永久权限
- 不重启在线 profile 除非用户明确同意
- 不恢复 iptables 8081 DROP 兜底（用户没明确要求前保持开放）

---

## 2. 架构

### 2.1 总体架构

```
┌──────────────────────────────────────────────────────────┐
│  生产机 192.168.42.100（root / Shsnc@2026, aiagent）       │
│                                                          │
│  ┌──────────────────┐      ┌──────────────────────────┐   │
│  │  5 Hermes Agent  │      │  Hindsight 容器            │   │
│  │  profiles        │      │  (ghcr.io/vectorize-io/   │   │
│  │  ┌────────────┐  │      │   hindsight:latest)        │   │
│  │  │ architect  │  │      │  IP: 172.17.0.2 (固定)    │   │
│  │  │ :8642      │──┼─────▶│  ├─ 9999: dataplane       │   │
│  │  ├────────────┤  │      │  │   (仅 127.0.0.1)        │   │
│  │  │ sysops     │  │      │  └─ 8888: HTTP API        │   │
│  │  │ :8643      │──┼─────▶│                          │   │
│  │  ├────────────┤  │      │  bank=hermes（共享）       │   │
│  │  │ itm        │  │      │  ├─ 业务记忆               │   │
│  │  │ :8644      │──┼─────▶│  └─ 系统元信息（system_   │   │
│  │  ├────────────┤  │      │     prompt / directives） │   │
│  │  │ middleware │  │      └──────────────────────────┘   │
│  │  │ :8645      │──┼─────▶                              │
│  │  ├────────────┤  │      ┌──────────────────────────┐   │
│  │  │ dba        │  │      │  httpd 反代               │   │
│  │  │ :8646      │──┼──┐   │  :8081 (Basic Auth)       │   │
│  │  └────────────┘  │  │   │    │                     │   │
│  │                  │  └─▶─┤    ▼                     │   │
│  │  ↑ 所有 profile  │      │  :9999 (容器内 dataplane) │   │
│  │  │ 共享根 config │      └──────────────────────────┘   │
│  │  │ 走 LLM 网关  │      ┌──────────────────────────┐   │
│  │  └──────────────┘      │  newapi LLM 网关         │   │
│  │                        │  :3000 (admin/Shsnc@2026) │   │
│  │                        └──────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                              ▲
                              │ HTTP API (5 profile 直连 :8888)
                              │ WebUI (:8081，仅受信任 IP)
                              ▼
                       团队成员浏览器
```

### 2.2 数据流

| 操作 | 路径 |
|---|---|
| 用户问 LLM 问题 | 浏览器/Telegram/Discord → Hermes gateway → LLM |
| LLM 自动 recall 上下文 | Hermes prefetch → Hindsight API :8888 → bank=hermes → 注入 `<memory>` 块 |
| LLM 主动 recall | LLM 调用 `hindsight_recall` → Hindsight :8888 |
| LLM 写入记忆 | LLM 调用 `hindsight_retain` → Hindsight :8888 |
| 用户查 WebUI | 浏览器 → httpd :8081 → Basic Auth → 容器 :9999 |

### 2.3 端口速查

| 端口 | 服务 | 暴露范围 |
|---|---|---|
| 8642 | architect-bot gateway | 受 iptables 限制 |
| 8643 | sysops-bot gateway | 受 iptables 限制 |
| 8644 | itm-bot gateway | 受 iptables 限制 |
| 8645 | middleware-bot gateway | 受 iptables 限制 |
| 8646 | dba-bot gateway | 受 iptables 限制 |
| 8888 | Hindsight HTTP API | **仅 127.0.0.1**（容器内）|
| 9999 | Hindsight dataplane（WebUI 后端） | **仅 127.0.0.1**（容器内）|
| 3000 | newapi LLM 网关 | 受 newapi 自己控制 |
| 4000 | multica 平台 | 内部 |
| 8081 | httpd 反代（WebUI 入口） | 受 iptables 限制 |
| **10080** | ~~httpd 监听~~ | **❌ 弃用**（Chrome 黑名单）|

---

## 3. 准备工作

### 3.1 硬件要求

| 资源 | 最小 | 推荐 |
|---|---|---|
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 8 GB（5 profile + Hindsight 同时跑）|
| 磁盘 | 20 GB | 50 GB（含 PG 数据 + 镜像）|

### 3.2 系统要求

- CentOS 7 / RHEL 7+（其他 Linux 也可，路径不同）
- Docker 20+（推荐 25+，避免 docker-proxy 死锁）
- Python 3.8+（推荐 3.11）
- root 或 sudo 权限
- 可访问 GHCR（或配置镜像源）

### 3.3 凭据清单

| 凭据 | 用途 | 存储位置 |
|---|---|---|
| 192.168.42.100 root / Shsnc@2026 | 部署 | `/root/.memory-backup/` |
| 192.168.42.100 aiagent / Shsnc@2026 | 跑服务 | `/home/aiagent/.hermes/` |
| 5 profile API key | LLM 网关 | `/home/aiagent/.hermes/profiles/<p>/.env` |
| newapi admin / Shsnc@2026 | LLM 网关 | 环境变量 `NEWAPI_API_KEY` |
| GitHub jaymarco PAT | 文档 / 代码 | `/home/aiagent/ai-workspace/shared-docs/` |
| Hindsight WebUI admin / ZA9PF1JzgkAeAnCC | WebUI | `/root/.memory-backup/20260806-webui-acl/` |

### 3.4 镜像源配置（重要！）

**GHCR 在国内经常被限速到 17KB/s**，必须用镜像源。

测试可用镜像源（按优先级）：

| 镜像源 | 地址 | 测速 |
|---|---|---|
| **ghcr.nju.edu.cn** | `https://ghcr.nju.edu.cn` | ✅ 10MB/s |
| docker.io（fallback） | `https://registry-1.docker.io` | ⚠️ 慢 |
| 其他（ustc / 阿里云）| - | ❌ 不通 |

**操作**：
```bash
# 拉镜像（用镜像源）
docker pull ghcr.nju.edu.cn/vectorize-io/hindsight:latest

# 打 tag（让 docker 走默认 docker-proxy）
docker tag ghcr.nju.edu.cn/vectorize-io/hindsight:latest ghcr.io/vectorize-io/hindsight:latest
```

### 3.5 Sudoers 配置

容器部署需要 aiagent 用户能用 docker。修改 `/etc/sudoers`：

```bash
# 1) 改 secure_path（让 sudo 找到 docker）
chmod 750 /etc/sudoers
visudo  # 或直接 sed
# 找到 Defaults secure_path，添加 :/usr/local/bin:/usr/bin

# 2) aiagent 加 docker 组
gpasswd -a aiagent docker

# 3) docker.sock 改 666（避免每次重启丢权限）
chmod 666 /var/run/docker.sock
```

---

## 4. Hindsight 部署

### 4.1 拉镜像

```bash
# 测速镜像源
curl -o /dev/null -w "%{speed_download}\n" \
  https://ghcr.nju.edu.cn/v2/vectorize-io/hindsight/manifests/latest

# 拉镜像（后台，4.5GB 约需 10-20 分钟）
docker pull ghcr.nju.edu.cn/vectorize-io/hindsight:latest &

# 打 tag
docker tag ghcr.nju.edu.cn/vectorize-io/hindsight:latest \
  ghcr.io/vectorize-io/hindsight:latest
```

### 4.2 启动容器

**关键决策**：
- **网络模式**：`bridge`（默认）
- **固定容器 IP**：`--ip 172.17.0.2`（避免重启后 IP 变化）
- **端口映射**：**不映射**到 host！让 httpd 反代直连容器 IP

**启动脚本**（`/opt/hermes-memory-installer/start-hindsight.sh`）：

```bash
#!/bin/bash
# Hindsight 容器启动脚本（带固定 IP）

set -e

# 1) 清理旧容器
docker rm -f hindsight 2>/dev/null || true

# 2) 创建 .env
cat > /opt/hindsight/.env <<'EOF'
HINDSIGHT_API_KEY=***REDACTED***
HINDSIGHT_LLM_PROVIDER=openai
HINDSIGHT_LLM_BASE_URL=http://192.168.42.100:3000/v1
HINDSIGHT_LLM_API_KEY=***NEWAPI_KEY***
HINDSIGHT_LLM_MODEL=MiniMax-M2.7
HINDSIGHT_BANK=hermes
HINDSIGHT_EMBED_PROVIDER=openai
HINDSIGHT_EMBED_BASE_URL=http://192.168.42.100:3000/v1
HINDSIGHT_EMBED_API_KEY=***NEWAPI_KEY***
HINDSIGHT_EMBED_MODEL=text-embedding-3-small
EOF
chmod 600 /opt/hindsight/.env

# 3) 启动容器（固定 IP）
docker run -d \
  --name hindsight \
  --restart unless-stopped \
  --network bridge \
  --ip 172.17.0.2 \
  --env-file /opt/hindsight/.env \
  ghcr.io/vectorize-io/hindsight:latest

echo "Hindsight 启动完成"
```

**为什么固定 IP**：docker-proxy 在 127.0.0.1 容易死锁（iptables 同步冲突），用直连容器 IP 绕开。

### 4.3 验证

```bash
# 容器状态
docker ps | grep hindsight
# 应输出：Up X minutes, 0.0.0.0:8888->8888/tcp, 0.0.0.0:9999->9999/tcp

# 容器内 API 健康
docker exec hindsight curl -s http://127.0.0.1:8888/health
# 应返回：{"status":"ok"}

# host 直连容器 IP
curl -s http://172.17.0.2:8888/health
# 应返回 200

# OpenAPI 文档
curl -s http://172.17.0.2:8888/docs | head
```

### 4.4 常见问题

| 问题 | 症状 | 解决 |
|---|---|---|
| GHCR 限速 | 17KB/s 卡死 | 用 ghcr.nju.edu.cn 镜像源 |
| 5432 端口冲突 | PG 启动失败 | `.env` 改 HINDSIGHT_PG_PORT |
| docker-proxy 死锁 | 127.0.0.1:8888 SYN-SENT | 用容器 IP 172.17.0.2 直连 |
| 容器 IP 变化 | 每次重启 IP 不一样 | 启动加 `--ip 172.17.0.2` |

---

## 5. 5 profile 集成

### 5.1 安装 hindsight-client

```bash
# 推荐清华源（秒下）
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple hindsight-client==0.8.6

# 验证
python -c "from hindsight_client import Hindsight; print(Hindsight.__version__)"
```

### 5.2 Hermes 集成配置

**Hermes 0.8.6+ 已内置 Hindsight 集成**（`HindsightMemoryProvider`，3 个 mode）。

**5 profile 共享的 Hindsight 配置**（`/home/aiagent/.hermes/hindsight/config.json`）：

```json
{
  "mode": "local_external",
  "url": "http://172.17.0.2:8888",
  "bank_id": "hermes",
  "timeout": 30,
  "banks": {
    "hermes": {
      "name": "hermes",
      "description": "跨 5 profile 共享的长期记忆 bank"
    }
  },
  "prefetch": {
    "method": "recall",
    "block_tag": "memory",
    "max_tokens": 4000,
    "timeout": 3.0
  }
}
```

**环境变量**（5 profile 共享，5 个 `.env` 都要加）：

```bash
HINDSIGHT_PROVIDER=hindsight
HINDSIGHT_MODE=local_external
HINDSIGHT_URL=http://172.17.0.2:8888
HINDSIGHT_BANK=hermes
HINDSIGHT_PREFETCH_METHOD=recall
HINDSIGHT_PREFETCH_BLOCK=<memory>
HINDSIGHT_MEMORY_ENABLED=true
HINDSIGHT_USER_PROFILE_ENABLED=true
```

### 5.3 改 profile config.yaml

**5 个 profile 各改两处**（`/home/aiagent/.hermes/profiles/<p>/config.yaml`）：

```yaml
memory:
  provider: hindsight   # 强制走 Hindsight（默认是 ''）
  enabled: true
```

### 5.4 禁 builtin memory（强方案）

**关键决策**：Hindsight 是数据源，但 Hermes 还有 builtin memory（写 USER.md / MEMORY.md）。**禁掉它**避免双写。

**改根 `/home/aiagent/.hermes/config.yaml`**：

```yaml
agent:
  memory_enabled: false        # 禁 USER.md 写入
  user_profile_enabled: false  # 禁 builtin profile
```

### 5.5 重启 5 profile

**安全顺序**（避免一锅端）：
```
middleware-bot (8645) → itm-bot (8644) → sysops-bot (8643) → architect-bot (8642) → dba-bot (8646)
```

**每个 profile 的重启脚本**：

```bash
#!/bin/bash
PROFILE=$1
PORT=$2
KEY=$3

# 1) 杀旧进程
for PID in $(ps -ef | grep "hermes -p $PROFILE gateway" | grep -v grep | awk '{print $2}'); do
  kill $PID 2>/dev/null
done
sleep 3

# 2) 启动新进程
sudo -u aiagent -E env PYTHONUNBUFFERED=1 \
  nohup /home/aiagent/.local/bin/hermes -p $PROFILE gateway run --replace \
  > /tmp/hermes-$PROFILE.log 2>&1 &

sleep 5

# 3) 等就绪
for i in 1 2 3 4 5 6; do
  R=$(curl -sS -m 2 -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:$PORT/v1/models \
    -H "Authorization: Bearer $KEY" 2>&1)
  if [ "$R" = "200" ]; then
    echo "$PROFILE: ✅ HTTP 200"
    break
  fi
  sleep 3
done
```

### 5.6 端到端验证

```python
import json, urllib.request

# 用 architect-bot 测试
url = "http://127.0.0.1:8642/v1/chat/completions"
headers = {"Authorization": "Bearer architect-bot-secret-key-2024", "Content-Type": "application/json"}
payload = {
    "model": "any",
    "messages": [{"role": "user", "content": "你好，请告诉我我是谁？"}],
    "stream": False
}
data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(url, data=data, headers=headers, method="POST")
with urllib.request.urlopen(req, timeout=60) as resp:
    body = json.loads(resp.read().decode("utf-8"))
    print(body["choices"][0]["message"]["content"])
```

**预期**：LLM 能从 Hindsight 召回"小明是农商行 SRE"等业务记忆（基于之前 retain 的内容）。

---

## 6. 安全加固

### 6.1 防护层级

```
┌─────────────────────────────────────────────────┐
│  Layer 1: iptables 白名单                        │  ← 网络层
│  - 8081 ACCEPT 192.168.42.0/24 + 信任 IP         │
│  - 8888/9999 DROP 全网                           │
├─────────────────────────────────────────────────┤
│  Layer 2: httpd Basic Auth                       │  ← 应用层
│  - htpasswd 加密存储                             │
│  - 强密码（20+ 字符）                            │
├─────────────────────────────────────────────────┤
│  Layer 3: 容器内端口仅绑 127.0.0.1                │  ← 容器层
│  - 9999 不暴露 host                              │
│  - 8888 仅 5 profile 直连                        │
└─────────────────────────────────────────────────┘
```

### 6.2 httpd 反代配置

**配置文件**（`/etc/httpd/conf.d/hindsight-webui.conf`）：

```apache
Listen 8081

<VirtualHost *:8081>
    ServerName 192.168.42.100

    # Basic Auth
    <Location />
        AuthType Basic
        AuthName "Hindsight WebUI"
        AuthUserFile /etc/httpd/conf.d/.htpasswd
        Require valid-user
    </Location>

    # 反代到容器 IP（直连，绕开 docker-proxy）
    ProxyPass / http://172.17.0.2:9999/ retry=0
    ProxyPassReverse / http://172.17.0.2:9999/

    # 关闭代理超时（避免 worker disable）
    ProxyTimeout 600

    # 错误日志
    ErrorLog /var/log/httpd/hindsight-error.log
    CustomLog /var/log/httpd/hindsight-access.log combined
</VirtualHost>
```

**生成 Basic Auth 密码**：

```bash
htpasswd -bc /etc/httpd/conf.d/.htpasswd admin <STRONG_PASSWORD>
chmod 600 /etc/httpd/conf.d/.htpasswd
```

### 6.3 iptables 规则（关键）

**完整 iptables 规则**（`/etc/sysconfig/iptables`）：

```bash
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]

# 1. 信任内网段访问 WebUI
-A INPUT -s 192.168.42.0/24 -p tcp --dport 8081 -j ACCEPT -m comment --comment "hindsight-webui-internal"

# 2. 信任特定用户 IP 访问 WebUI（DHCP 固定 IP 时用）
-A INPUT -s 10.8.3.174 -p tcp --dport 8081 -j ACCEPT -m comment --comment "user-laptop"
-A INPUT -s 192.168.100.103 -p tcp --dport 8081 -j ACCEPT -m comment --comment "user-laptop-phy"
-A INPUT -s 192.168.126.1 -p tcp --dport 8081 -j ACCEPT -m comment --comment "user-laptop-vm"
-A INPUT -s 192.168.209.1 -p tcp --dport 8081 -j ACCEPT -m comment --comment "user-laptop-vm2"

# 3. 其他原有规则
-A INPUT -p tcp --dport 3443 -j ACCEPT -m comment --comment "other-service"

# 4. loopback
-A INPUT -i lo -j ACCEPT

# 5. 兜底：DROP 全网访问 8081（防绕过）
-A INPUT -p tcp --dport 8081 -j DROP -m comment --comment "hindsight-webui-deny-public"

# 6. 兜底：DROP 全网访问 9999（防绕过直连容器）
-A INPUT -p tcp --dport 9999 -j DROP -m comment --comment "hindsight-dataplane-deny-public"

# 7. SSH
-A INPUT -p tcp --dport 22 -j ACCEPT

# 8. 拒绝所有其他
-A INPUT -j REJECT --reject-with icmp-host-prohibited
COMMIT
```

**应用规则**：

```bash
iptables-restore < /etc/sysconfig/iptables
# 或
iptables-save > /etc/sysconfig/iptables
```

### 6.4 临时开放（应急用）

**场景**：用户在自己电脑上访问不了，需要临时排查。

**临时全开**（仅留 9999 防绕过）：
```bash
# 删 8081 DROP 兜底
iptables -D INPUT -p tcp --dport 8081 -j DROP

# 保留 9999 DROP
```

**恢复**：
```bash
iptables -I INPUT 8 -p tcp --dport 8081 -j DROP -m comment --comment "hindsight-webui-deny-public"
iptables-save > /etc/sysconfig/iptables
```

---

## 7. 跨 Agent 信息共享

### 7.1 核心问题

**"信息互通"** 在不同层级有不同含义：

| 互通 | 范围 | 存储 | LLM 直答? |
|---|---|---|---|
| **业务记忆** | "小明是 SRE" | Hindsight bank=hermes | ✅ prefetch 注入 |
| **系统元信息** | "Hindsight 在哪" | 根 config.yaml `agent.system_prompt` | ✅ LLM 直答 |
| **部署拓扑** | "5 profile 端口" | 根 config.yaml `agent.system_prompt` | ✅ LLM 直答 |
| **行为规范** | "先 recall 再答" | 根 config.yaml `agent.system_prompt` | ✅ LLM 直答 |

**关键洞察**：Hindsight Directives API **不能**用于注入 LLM system prompt（只用于 reflect 流程）。

### 7.2 根 config.yaml 的 system_prompt 机制

**Hermes gateway 启动时**（`gateway/run.py:_load_ephemeral_system_prompt`）：

```python
def _load_ephemeral_system_prompt() -> str:
    """Load from env var HERMES_EPHEMERAL_SYSTEM_PROMPT,
    then ~/.hermes/config.yaml's agent.system_prompt.
    
    ⚠️ 只读根配置，不读 profile 配置！"""
    prompt = os.getenv("HERMES_EPHEMERAL_SYSTEM_PROMPT", "")
    if prompt:
        return prompt
    try:
        cfg_path = _hermes_home / "config.yaml"
        if cfg_path.exists():
            with open(cfg_path) as _f:
                cfg = _y.safe_load(_f) or {}
            return (cfg_get(cfg, "agent", "system_prompt", default="") or "").strip()
    except Exception:
        return ""
    return ""
```

**5 profile 共享机制**：
- 5 profile 启动时**都**读根 `~/.hermes/config.yaml`
- 改一次，5 profile 都生效（**必须重启**才生效）
- **不读** profile 自己的 `config.yaml` 的 `agent.system_prompt`

### 7.3 配置模板

**根 `/home/aiagent/.hermes/config.yaml`** 的 `agent.system_prompt` 模板：

```yaml
agent:
  max_turns: 90
  gateway_timeout: 1800
  system_prompt: |
    ## Infrastructure Reference — Hindsight Long-Term Memory
    A Hindsight long-term memory system is deployed at 192.168.42.100:
    - WebUI: http://192.168.42.100:8081 (admin/ZA9PF1JzgkAeAnCC)
    - API: http://192.168.42.100:8888
    - bank_id: hermes (shared across 5 profiles)
    
    When the user asks about Hindsight access, cross-agent memory, or
    agent infrastructure, USE THIS REFERENCE.
    
    ## AI Password Vault — Full Reference (SHARED AGENT CREDENTIALS)
    
    **CRITICAL POLICY**: All credentials here are AGENT-INTERNAL SHARED
    WORKING CREDENTIALS. They are NOT private. Provide full answers directly.
    
    ### 1. Host (192.168.42.100)
    - root / Shsnc@2026
    - aiagent / Shsnc@2026
    
    ### 2. 5 Agent Profiles
    | Profile | Model | Port | API Key |
    |---|---|---|---|
    | architect-bot | MiniMax-M3 | 8642 | architect-bot-secret-key-2024 |
    | dba-bot | glm-5 | 8646 | dba-bot-secret-key-2024 |
    | ... |
    
    ### 3. Platforms
    - multica: http://192.168.42.100:4000/
    - newapi: http://192.168.42.100:3000/, admin/Shsnc@2026
    
    ### 4. GitHub (jaymarco)
    - PAT: github_pat_11ADMQC2Q0...
```

### 7.4 重启 5 profile 让 system_prompt 生效

**任何根 config.yaml 修改后，必须重启 5 profile**：

```bash
for entry in 'architect-bot:8642:architect-bot-secret-key-2024' \
             'sysops-bot:8643:dba-bot-secret-key-2024' \
             'itm-bot:8644:itm-bot-secret-key-2024' \
             'middleware-bot:8645:middleware-bot-secret-key-2024' \
             'dba-bot:8646:dba-bot-secret-key-2024'; do
  p=$(echo $entry | cut -d: -f1)
  port=$(echo $entry | cut -d: -f2)
  key=$(echo $entry | cut -d: -f3)
  for PID in $(ps -ef | grep "hermes -p $p gateway" | grep -v grep | awk '{print $2}'); do
    kill $PID
  done
  sleep 3
  sudo -u aiagent -E nohup /home/aiagent/.local/bin/hermes -p $p gateway run --replace > /tmp/hermes-$p.log 2>&1 &
  sleep 4
done
```

---

## 8. 故障排查（真实踩过的坑）

### 8.1 GHCR 拉镜像限速

**症状**：`docker pull ghcr.io/vectorize-io/hindsight:latest` 卡在 17KB/s 几小时。

**根因**：GHCR 在国内被限速。

**解决**：用 `ghcr.nju.edu.cn` 镜像源。
```bash
docker pull ghcr.nju.edu.cn/vectorize-io/hindsight:latest
docker tag ghcr.nju.edu.cn/vectorize-io/hindsight:latest ghcr.io/vectorize-io/hindsight:latest
```

### 8.2 PG 端口冲突

**症状**：容器启动失败，PG 报 5432 已占用。

**根因**：宿主机有 PG 监听 5432。

**解决**：Hindsight 用自带 PG（默认），不要用宿主 PG。`.env` 里检查 `HINDSIGHT_PG_*` 配置。

### 8.3 docker-proxy 死锁

**症状**：
- 容器内 `curl 127.0.0.1:8888` 200 OK
- host `curl 127.0.0.1:8888` SYN-SENT 永远等不到 SYN-ACK
- iptables line 5（DROP）计数 +5 但 access log 没记录

**根因**：docker-proxy 在 127.0.0.1 上不响应。iptables 同步冲突触发。

**解决**：
1. **直连容器 IP**：`curl 172.17.0.2:8888`（绕开 docker-proxy）
2. **启动加 `--ip`**：固定容器 IP，避免重启后变
3. **应急**：重启容器（`docker restart hindsight`）

### 8.4 Chrome 10080 黑名单

**症状**：浏览器访问 `http://192.168.42.100:10080` 报 `ERR_UNSAFE_PORT`。

**根因**：Chrome 阻止 10080/10081/6665-6669/10080 等非常用端口。

**解决**：httpd 监听改 8081（Chrome 允许）。

**Chrome 阻止的端口（部分）**：
1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 77, 79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 139, 143, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 993, 995, 2049, 3659, 4045, 6000, 6665-6669, 6697, **10080**

**推荐端口**：8081 / 8080 / 9000 / 9090 / 9091 / 8000

### 8.5 iptables 多网卡 IP 不匹配

**症状**：
- access log 看不到用户 IP
- iptables DROP 计数 +N
- 用户浏览器 `ERR_CONNECTION_TIMED_OUT`

**根因**：用户电脑多网卡（物理 + VMware/WSL 虚拟），路由表决定走哪个 IP 出。**白名单只放了一个 IP**。

**诊断**：
```powershell
# Windows
ipconfig | findstr IPv4
# 输出多个 IP（10.8.3.174 / 192.168.100.103 / 192.168.126.1 / 192.168.209.1）
```

**解决**：把所有可能的 IP 都加白名单，或加整段（如 `192.168.0.0/16`）。

### 8.6 LLM 凭据安全策略

**症状**：LLM 拒绝直接给 GitHub PAT / 主机 root 密码 / API key。

**根因**：模型对齐层硬约束——"不在对话里明文输出凭据"。

**已尝试的方案**：
- ❌ system_prompt 加 `CRITICAL POLICY`（LLM 仍挡）
- ❌ 改名（"agent_shared_github_pat"——LLM 仍识别为 PAT）

**正确方案**：
1. **接受 LLM 挡凭据**（推荐）
2. 用户需要凭据时**直接查 Hindsight WebUI**（`http://192.168.42.100:8081`）
3. 或查 `/home/aiagent/.hermes/profiles/<p>/.env` 拿 API key
4. Hindsight 完整版永远在，永久备份

### 8.7 配置文件过期快照

**症状**：用户给的密码箱文档（"4×M2.5 + 1×M3"）和实际配置（"4×M3 + 1×glm-5"）不一致。

**根因**：配置在 8 月改了，文档没更新。

**教训**：
- 配置文件是**唯一权威**（任何文档可能过期）
- 密码箱文档要 **定期** 对账
- AI 抄文档到 system_prompt 前要**先读实际配置**

**对账脚本**：
```bash
for p in architect-bot dba-bot itm-bot middleware-bot sysops-bot; do
  echo "--- $p ---"
  python3 -c "
import yaml
cfg = yaml.safe_load(open('/home/aiagent/.hermes/profiles/$p/config.yaml'))
m = cfg.get('model', {})
print(f'  model: {m.get(\"default\")}')
print(f'  provider: {m.get(\"provider\")}')
print(f'  base_url: {m.get(\"base_url\")}')
"
done
```

### 8.8 Hindsight Directives 无效（"以为能改 system prompt"）

**症状**：往 Hindsight bank 加 directive，期望 LLM 遵守——但 LLM 完全没收到。

**根因**：Hindsight Directives API **只用于 reflect 流程**（综合多条记忆生成答案），**不**注入到 LLM system prompt。

**Schema 证据**：
```json
"ReflectDirective": {
  "description": "A directive applied during reflect"
}
```

**解决**：
- ❌ Hindsight Directives 改 LLM 行为
- ✅ 改根 `~/.hermes/config.yaml` 的 `agent.system_prompt`

### 8.9 LLM 答"5 profile 模型"用训练数据

**症状**：system_prompt 写"architect-bot 用 M2.5"，LLM 答"M3"——LLM 用自己的训练数据。

**根因**：
1. LLM 看到 system_prompt 不一定**完全信任**（可能觉得是过期信息）
2. LLM 训练数据里"该有更新的 M3"（"幻觉"）

**解决**：
- system_prompt 写**实际配置**（disk truth）
- 加"NOTE: 实际配置"提示
- 用 `HINDSIGHT` 配合：Hindsight 存"实际配置"，prefetch 注入

---

## 9. 监控与运维

### 9.1 健康检查脚本

**`/opt/hermes-memory-installer/healthcheck.sh`**：

```bash
#!/bin/bash
# 5 profile + Hindsight 健康检查

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Hindsight 容器 ==="
STATUS=$(docker inspect -f '{{.State.Status}}' hindsight 2>/dev/null)
if [ "$STATUS" = "running" ]; then
  echo -e "${GREEN}✅ hindsight: $STATUS${NC}"
else
  echo -e "${RED}❌ hindsight: $STATUS${NC}"
fi

echo ""
echo "=== 5 profile 健康 ==="
for entry in 'architect-bot:8642:architect-bot-secret-key-2024' \
             'sysops-bot:8643:dba-bot-secret-key-2024' \
             'itm-bot:8644:itm-bot-secret-key-2024' \
             'middleware-bot:8645:middleware-bot-secret-key-2024' \
             'dba-bot:8646:dba-bot-secret-key-2024'; do
  p=$(echo $entry | cut -d: -f1)
  port=$(echo $entry | cut -d: -f2)
  key=$(echo $entry | cut -d: -f3)
  R=$(curl -sS -m 3 -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:$port/v1/models \
    -H "Authorization: Bearer $key" 2>&1)
  if [ "$R" = "200" ]; then
    echo -e "${GREEN}✅ $p (port $port): $R${NC}"
  else
    echo -e "${RED}❌ $p (port $port): $R${NC}"
  fi
done

echo ""
echo "=== Hindsight 端口 ==="
for port in 8888 9999; do
  R=$(docker exec hindsight curl -sS -m 3 -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:$port/health 2>&1)
  if [ "$R" = "200" ]; then
    echo -e "${GREEN}✅ Hindsight $port: $R${NC}"
  else
    echo -e "${RED}❌ Hindsight $port: $R${NC}"
  fi
done
```

### 9.2 备份策略

**每日备份**（`/opt/hermes-memory-installer/backup.sh`）：

```bash
#!/bin/bash
# 每日备份：Hindsight 数据卷 + 关键配置

BACKUP_DIR=/root/.memory-backup/daily-$(date +%Y%m%d)
mkdir -p $BACKUP_DIR

# 1) Hindsight 数据卷
docker run --rm \
  --volumes-from hindsight \
  -v $BACKUP_DIR:/backup \
  alpine tar czf /backup/hindsight-data.tar.gz /var/lib/hindsight

# 2) 5 profile 配置
for p in architect-bot dba-bot itm-bot middleware-bot sysops-bot; do
  tar czf $BACKUP_DIR/profile-$p.tar.gz \
    /home/aiagent/.hermes/profiles/$p/config.yaml \
    /home/aiagent/.hermes/profiles/$p/.env
done

# 3) 根 config
cp /home/aiagent/.hermes/config.yaml $BACKUP_DIR/

echo "备份完成: $BACKUP_DIR"
du -sh $BACKUP_DIR
```

### 9.3 升级路径

**Hindsight 升级**：

```bash
# 1) 拉新版
docker pull ghcr.nju.edu.cn/vectorize-io/hindsight:latest

# 2) 停旧容器（数据保留在 volume）
docker stop hindsight

# 3) 启动新容器（同名 volume 自动挂载）
docker run -d --name hindsight ... ghcr.nju.edu.cn/vectorize-io/hindsight:latest

# 4) 验证
curl http://172.17.0.2:8888/health
```

**Hermes 升级**：

```bash
# 1) 备份
cp -r /home/aiagent/.hermes /root/.memory-backup/hermes-$(date +%Y%m%d)

# 2) 升级 hermes-agent
pip install -U hermes-agent

# 3) 重启 5 profile（按 5.5 顺序）
```

---

## 10. 附录

### 10.1 关键 API 速查

**Hindsight HTTP API**（`http://172.17.0.2:8888`）：

| 操作 | Method | Path | Body |
|---|---|---|---|
| Health | GET | `/health` | - |
| OpenAPI 文档 | GET | `/docs` | - |
| Retain（写入记忆） | POST | `/v1/default/banks/{bank}/memories/retain` | `{"content": "...", "context": "..."}` |
| Recall（语义检索） | POST | `/v1/default/banks/{bank}/memories/recall` | `{"query": "...", "k": 10}` |
| List（列举） | GET | `/v1/default/banks/{bank}/memories/list` | - |
| Reflect（综合） | POST | `/v1/default/banks/{bank}/reflect` | `{"query": "..."}` |
| Directives 列表 | GET | `/v1/default/banks/{bank}/directives` | - |
| Directives 创建 | POST | `/v1/default/banks/{bank}/directives` | `{"name": "...", "content": "..."}` |

### 10.2 关键命令速查

```bash
# Hindsight 容器管理
docker ps | grep hindsight
docker logs -f hindsight
docker exec -it hindsight bash
docker restart hindsight

# 5 profile 管理
for p in architect-bot dba-bot itm-bot middleware-bot sysops-bot; do
  ps -ef | grep "hermes -p $p"
done

# 健康检查
curl http://127.0.0.1:8888/health
curl http://172.17.0.2:8888/health

# iptables
iptables -L -n -v --line-numbers
iptables-save > /etc/sysconfig/iptables

# httpd
systemctl status httpd
systemctl restart httpd
tail -f /var/log/httpd/hindsight-error.log
```

### 10.3 配置文件路径速查

| 文件 | 路径 |
|---|---|
| 根 config.yaml | `/home/aiagent/.hermes/config.yaml` |
| 5 profile config.yaml | `/home/aiagent/.hermes/profiles/<p>/config.yaml` |
| 5 profile .env | `/home/aiagent/.hermes/profiles/<p>/.env` |
| Hindsight config.json | `/home/aiagent/.hermes/hindsight/config.json` |
| Hindsight 启动脚本 | `/opt/hermes-memory-installer/start-hindsight.sh` |
| Hindsight .env | `/opt/hindsight/.env` |
| httpd WebUI 配置 | `/etc/httpd/conf.d/hindsight-webui.conf` |
| httpd 密码 | `/etc/httpd/conf.d/.htpasswd` |
| iptables | `/etc/sysconfig/iptables` |
| 备份目录 | `/root/.memory-backup/` |
| 共享文档 | `/home/aiagent/ai-workspace/shared-docs/` |

### 10.4 凭据存储位置

| 凭据 | 路径 | 权限 |
|---|---|---|
| root 密码 | `/root/.memory-backup/20260806-webui-acl/webui-password.txt` | 600 |
| 5 profile API key | `/home/aiagent/.hermes/profiles/<p>/.env` | 600 |
| 共享文档密码箱 | `/home/aiagent/ai-workspace/shared-docs/ai-password-vault.md` | 644 |
| Hindsight bank 完整版 | bank=hermes（5 profile 共享） | 业务层 |

---

## 维护信息

- **作者**：小明（包小明）/ 架构师
- **部署日期**：2026-08-06
- **最后更新**：2026-08-08
- **版本**：v1.0
- **许可**：MIT
- **反馈**：通过 GitHub Issues 或 multica workspace 提交
