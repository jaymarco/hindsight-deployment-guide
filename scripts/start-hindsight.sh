#!/bin/bash
# Hindsight 容器启动脚本（带固定 IP）
# ⚠️ 占位符需替换为实际值后再执行

set -e

# === 部署前请替换这些占位符 ===
PROD_HOST_IP="{{PROD_HOST_IP}}"
HINDSIGHT_CONTAINER_IP="{{HINDSIGHT_CONTAINER_IP}}"
NEWAPI_HOST="$PROD_HOST_IP"
NEWAPI_PORT="3000"
NEWAPI_KEY="{{NEWAPI_KEY}}"
LLM_MODEL="{{LLM_MODEL}}"      # 例如 MiniMax-M2.7
EMBED_MODEL="{{EMBED_MODEL}}"  # 例如 text-embedding-3-small
INTERNAL_KEY="{{INTERNAL_KEY}}"

# 1) 清理旧容器
docker rm -f hindsight 2>/dev/null || true

# 2) 创建 .env
mkdir -p /opt/hindsight
cat > /opt/hindsight/.env <<EOF
HINDSIGHT_API_KEY=$INTERNAL_KEY
HINDSIGHT_LLM_PROVIDER=openai
HINDSIGHT_LLM_BASE_URL=http://$NEWAPI_HOST:$NEWAPI_PORT/v1
HINDSIGHT_LLM_API_KEY=$NEWAPI_KEY
HINDSIGHT_LLM_MODEL=$LLM_MODEL
HINDSIGHT_BANK=hermes
HINDSIGHT_EMBED_PROVIDER=openai
HINDSIGHT_EMBED_BASE_URL=http://$NEWAPI_HOST:$NEWAPI_PORT/v1
HINDSIGHT_EMBED_API_KEY=$NEWAPI_KEY
HINDSIGHT_EMBED_MODEL=$EMBED_MODEL
EOF
chmod 600 /opt/hindsight/.env

# 3) 启动容器（固定 IP）
docker run -d \
  --name hindsight \
  --restart unless-stopped \
  --network bridge \
  --ip $HINDSIGHT_CONTAINER_IP \
  --env-file /opt/hindsight/.env \
  ghcr.io/vectorize-io/hindsight:latest

echo "Hindsight 启动完成 (IP=$HINDSIGHT_CONTAINER_IP)"
echo "验证: curl http://$HINDSIGHT_CONTAINER_IP:8888/health"
