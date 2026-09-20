#!/bin/bash
# 下载 mihomo 离线分流数据到 assets/rules/（智能模式 CN 直连用）。
# 发布包由 CI 自动下载（见 .github/workflows/release.yml）；本地开发/测试用本脚本。
# 来源: MetaCubeX/meta-rules-dat 官方 release
#   geosite.dat   4MB  —— GEOSITE,cn 域名分类
#   country.mmdb  7.5MB —— GEOIP,CN IP 国家库（mihomo 默认文件名）
#   cn.mrs        0.5MB —— iOS 专用：域名规则集（mmap 直查，内存 ~2MB）
set -euo pipefail

BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/rules"
mkdir -p "$DIR"

# cn.mrs 在 meta 分支（不是 release 资产），单独取
MRS_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs"
if [ ! -s "$DIR/cn.mrs" ]; then
  echo "下载 cn.mrs ..."
  curl -fL --max-time 300 -o "$DIR/cn.mrs" "$MRS_URL" || echo "warning: cn.mrs 下载失败（iOS 智能分流会退化为全代理，其它平台不受影响）"
fi

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
