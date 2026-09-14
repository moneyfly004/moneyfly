#!/bin/bash
# 获取 mihomo 的 iOS 内核框架（Mihomelib.xcframework）到 ios/ 供 Xcode 链接。
#
# 为什么需要它：iOS 上内核不能作为子进程运行，必须以 gomobile 静态框架
# 链进 PacketTunnel 扩展（详见 ios/PacketTunnel/PacketTunnelProvider.swift）。
# 框架约 150MB/切片，不入库，构建前下载。
#
# 用法: bash tool/fetch_mihomo_ios.sh [版本号，默认 1.19.30]
# 产物来源: moneyfly004/mihomo-lib releases（与 Android 的 libmihomo.aar 同源）
set -euo pipefail

VERSION="${1:-1.19.30}"
REPO="moneyfly004/mihomo-lib"
ASSET="Mihomelib.xcframework.zip"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -d "$DEST/Mihomelib.xcframework" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "✓ ios/Mihomelib.xcframework 已存在（FORCE=1 可重新下载）"
  exit 0
fi

echo "下载 $ASSET (v$VERSION) ..."
curl -fL --retry 5 --retry-delay 3 --retry-all-errors --max-time 900 \
  -o "$TMP/$ASSET" "$BASE/$ASSET"

rm -rf "$DEST/Mihomelib.xcframework"
unzip -q -o "$TMP/$ASSET" -d "$DEST"
echo "✓ 已就位: ios/Mihomelib.xcframework"
find "$DEST/Mihomelib.xcframework" -maxdepth 2 -name "*.framework" 2>/dev/null | head
