#!/bin/bash
# Hindsight + 5 Hermes profile 健康检查脚本
# 每日 cron 推荐: 0 9 * * * /opt/hermes-memory-installer/healthcheck.sh >> /var/log/hermes-health.log 2>&1

# === 部署前请替换这些占位符 ===
HINDSIGHT_CONTAINER_IP="{{HINDSIGHT_CONTAINER_IP}}"

# 5 profile 配置
declare -A PROFILES
PROFILES[architect-bot]="{{ARCHITECT_BOT_KEY}}:8642"
PROFILES[sysops-bot]="{{SYSOPS_BOT_KEY}}:{{SYSOPS_BOT_PORT}}"
PROFILES[itm-bot]="{{ITM_BOT_KEY}}:{{ITM_BOT_PORT}}"
PROFILES[middleware-bot]="{{MIDDLEWARE_BOT_KEY}}:{{MIDDLEWARE_BOT_PORT}}"
PROFILES[dba-bot]="{{DBA_BOT_KEY}}:{{DBA_BOT_PORT}}"

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

echo
echo "=== 5 profile 健康 ==="
for p in "${!PROFILES[@]}"; do
  IFS=':' read -r key port <<< "${PROFILES[$p]}"
  R=$(curl -sS -m 3 -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:$port/v1/models \
    -H "Authorization: Bearer $key" 2>&1)
  if [ "$R" = "200" ]; then
    echo -e "${GREEN}✅ $p (port $port): $R${NC}"
  else
    echo -e "${RED}❌ $p (port $port): $R${NC}"
  fi
done

echo
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
