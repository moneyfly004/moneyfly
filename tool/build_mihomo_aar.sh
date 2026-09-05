#!/bin/bash
# 本地编译 libmihomo.aar（Android 内核库，官方 MetaCubeX/mihomo 源码 + gomobile bind）。
# 通常无需手动执行：CI（release.yml）构建时自动完成。本脚本供本地调试 Android 用。
#
# 依赖：
#   - Go >= 1.24（android/mihomo-core/go.mod 声明）
#   - Android NDK（ANDROID_NDK_HOME 或 ANDROID_HOME 下的 ndk）
# 用法: bash tool/build_mihomo_aar.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) NDK 环境检查
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    NDK="$(ls -1d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)"
    [ -n "${NDK:-}" ] && export ANDROID_NDK_HOME="$NDK"
  fi
fi
if [ -z "${ANDROID_NDK_HOME:-}" ] || [ ! -d "${ANDROID_NDK_HOME:-}" ]; then
  echo "错误: 未找到 Android NDK。请设置 ANDROID_NDK_HOME（或 ANDROID_HOME 下安装 ndk）。" >&2
  echo "示例: sdkmanager \"ndk;27.2.12479018\"; export ANDROID_NDK_HOME=\$ANDROID_HOME/ndk/27.2.12479018" >&2
  exit 1
fi

# 2) 编译（gomobile bind）
export PATH="$PATH:$(go env GOPATH)/bin"
command -v gomobile >/dev/null 2>&1 || go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

echo "编译 libmihomo.aar（ANDROID_NDK_HOME=$ANDROID_NDK_HOME）..."
mkdir -p android/app/libs
(cd android/mihomo-core && gomobile bind \
  -target=android \
  -androidapi 21 \
  -tags with_gvisor \
  -javapkg top.moneyfly \
  -o ../app/libs/libmihomo.aar .)
ls -lh android/app/libs/libmihomo.aar
echo "完成: android/app/libs/libmihomo.aar"
