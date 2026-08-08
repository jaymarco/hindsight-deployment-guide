#!/bin/bash
# Hindsight 数据卷 + 关键配置每日备份脚本
# 推荐每日 cron: 0 2 * * * /opt/hermes-memory-installer/backup.sh

set -e

# === 部署前请替换这些占位符 ===
BACKUP_ROOT="{{BACKUP_ROOT}}"  # 例如 /root/.memory-backup

BACKUP_DIR="$BACKUP_ROOT/daily-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# 1) Hindsight 数据卷（容器内路径 /var/lib/hindsight）
docker run --rm \
  --volumes-from hindsight \
  -v "$BACKUP_DIR:/backup" \
  alpine tar czf /backup/hindsight-data.tar.gz /var/lib/hindsight

# 2) 5 profile 配置
for p in architect-bot sysops-bot itm-bot middleware-bot dba-bot; do
  tar czf "$BACKUP_DIR/profile-$p.tar.gz" \
    /home/aiagent/.hermes/profiles/$p/config.yaml \
    /home/aiagent/.hermes/profiles/$p/.env 2>/dev/null || true
done

# 3) 根 config
cp /home/aiagent/.hermes/config.yaml "$BACKUP_DIR/"

# 4) 清理 30 天前
find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'daily-*' -mtime +30 -exec rm -rf {} +

echo "备份完成: $BACKUP_DIR"
du -sh "$BACKUP_DIR"
