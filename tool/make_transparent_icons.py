#!/usr/bin/env python3
"""把「只有带颜色 M、背景全透明」的品牌标记铺到所有平台图标。

设计（2026-10 产品要求）：
- 画布保留透明通道，**只有 M 字形着色**，没有黑底/圆角底板（浏览器图标那种单一标记感）；
- 唯一真源 `assets/icon-mark.png`（1024×1024 RGBA，透明底 + 品牌蓝 M），
  本脚本从它缩放生成各平台尺寸，改画稿只改这一张。

注意 iOS：App Store 要求图标不带 alpha，本脚本仍按产品要求输出透明 PNG
（走侧载 IPA 没问题）；若将来上架，需要另出一套不透明底版本。

用法： python3 tool/make_transparent_icons.py
"""
from __future__ import annotations

import glob
import os
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / 'assets/icon-mark.png'

# 各平台尺寸表
ANDROID = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}
MACOS = {
    'app_icon_16.png': 16,
    'app_icon_32.png': 32,
    'app_icon_64.png': 64,
    'app_icon_128.png': 128,
    'app_icon_256.png': 256,
    'app_icon_512.png': 512,
    'app_icon_1024.png': 1024,
}
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
ICO_TARGETS = [
    'assets/tray_icon.ico',
    'windows/runner/resources/app_icon.ico',
]
LOGO = ('assets/moneyfly-logo.png', 256)  # App 内 logo（首页左上角 / 登录页）


def load_master() -> Image.Image:
    if not MASTER.exists():
        raise SystemExit(f'✗ 缺少画稿 {MASTER}')
    im = Image.open(MASTER).convert('RGBA')
    a = im.split()[3]
    if a.getextrema() == (255, 255):
        raise SystemExit('✗ 画稿没有透明区域：本脚本要求「透明底 + 单色标记」的画稿')
    return im


def scaled(master: Image.Image, px: int) -> Image.Image:
    """等比缩放；保持透明通道（尺寸不同则用 LANCZOS，抗锯齿）"""
    return master.resize((px, px), Image.LANCZOS)


def main() -> int:
    master = load_master()
    done = []

    for d, px in ANDROID.items():
        p = ROOT / 'android/app/src/main/res' / d / 'ic_launcher.png'
        scaled(master, px).save(p, optimize=True)
        done.append(f'{p.relative_to(ROOT)} ({px}px)')

    for name, px in MACOS.items():
        p = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset' / name
        scaled(master, px).save(p, optimize=True)
        done.append(f'{p.relative_to(ROOT)} ({px}px)')

    for rel in ICO_TARGETS:
        p = ROOT / rel
        # ICO 多尺寸：PIL 会按 sizes 从最大帧等比缩放
        scaled(master, 256).save(p, format='ICO', sizes=ICO_SIZES)
        done.append(f'{rel} (多尺寸 ico)')

    rel, px = LOGO
    scaled(master, px).save(ROOT / rel, optimize=True)
    done.append(f'{rel} ({px}px，App 内 logo)')

    for line in done:
        print(f'  ✓ {line}')
    print(f'共更新 {len(done)} 个图标文件（画稿 {MASTER.name}）')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
