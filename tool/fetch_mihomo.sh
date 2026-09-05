#!/bin/bash
# 开发环境获取 mihomo 内核二进制（发布包由 CI 自动内置，见 .github/workflows/release.yml）
# 用法: bash tool/fetch_mihomo.sh [版本号，默认 1.19.30]
# 下载源: MetaCubeX/mihomo 官方 release（预编译产物，无需自行编译）
set -euo pipefail

VERSION="${1:-1.19.30}"
BASE="https://github.com/MetaCubeX/mihomo/releases/download/v$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$(uname -s)" in
  Darwin)
    ARCH="$(uname -m)"
    case "$ARCH" in
      arm64) ASSET="mihomo-darwin-arm64-v$VERSION.gz" ;;
      x86_64) ASSET="mihomo-darwin-amd64-v$VERSION.gz" ;;
      *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    echo "下载 $ASSET ..."
    curl -fL --max-time 300 -o "$TMP/mihomo.gz" "$BASE/$ASSET"
    gunzip -f "$TMP/mihomo.gz"
    chmod +x "$TMP/mihomo"
    # 放入已构建的 app bundle（Debug 与 Release 都放，flutter run / build 均可直接连接）
    for CONF in Debug Release; do
      APP="build/macos/Build/Products/$CONF/MoneyFly.app"
      if [ -d "$APP" ]; then
        mkdir -p "$APP/Contents/MacOS"
        cp "$TMP/mihomo" "$APP/Contents/MacOS/mihomo"
        chmod +x "$APP/Contents/MacOS/mihomo"
        codesign --force -s - "$APP/Contents/MacOS/mihomo" 2>/dev/null || true
        echo "已放入 $APP/Contents/MacOS/mihomo"
      fi
    done
    # 同时复制一份到 build/mihomo 备用（可用 MONEYFLY_MIHOMO 环境变量指向）
    mkdir -p build/mihomo
    cp "$TMP/mihomo" "build/mihomo/mihomo"
    chmod +x build/mihomo/mihomo
    echo "备用: build/mihomo/mihomo（export MONEYFLY_MIHOMO=$(pwd)/build/mihomo/mihomo）"
    echo "如果刚才没有构建过 App，请先 flutter build macos --debug 再重跑本脚本。"
    ;;
  *)
    echo "本脚本目前支持 macOS 开发环境；Windows 开发机请手动下载:"
    echo "  $BASE/mihomo-windows-amd64-v$VERSION.zip"
    echo "解压后将 mihomo.exe 放到与 moneyfly.exe 同目录（build/windows/x64/runner/Release/）。"
    ;;
esac
