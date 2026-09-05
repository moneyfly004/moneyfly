#!/bin/bash
# 下载 mihomo 离线分流数据到 assets/rules/（智能模式 CN 直连用）。
# 发布包由 CI 自动下载（见 .github/workflows/release.yml）；本地开发/测试用本脚本。
# 来源: MetaCubeX/meta-rules-dat 官方 release
#   geosite.dat   4MB  —— GEOSITE,cn 域名分类
#   country.mmdb  7.5MB —— GEOIP,CN IP 国家库（mihomo 默认文件名）
set -euo pipefail

BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/rules"
mkdir -p "$DIR"

for f in geosite.dat country.mmdb; do
  if [ -s "$DIR/$f" ]; then
    echo "已存在: $DIR/$f ($(du -h "$DIR/$f" | cut -f1))，跳过"
    continue
  fi
  echo "下载 $f ..."
  curl -fL --max-time 300 -o "$DIR/$f" "$BASE/$f"
  ls -lh "$DIR/$f"
done
echo "完成。assets/rules/ 内容："
ls -lh "$DIR"
