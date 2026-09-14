#!/usr/bin/env python3
"""生成 iOS App 图标（AppIcon.appiconset），使其与 Android / 桌面端一致。

为什么需要这个脚本：
- iOS 平台是用 `flutter create --platforms=ios` 生成的，图标是 Flutter 默认模板
  （白底蓝色 Flutter logo），与 Android / macOS / Windows 的品牌图标完全不同；
- iOS 要求图标**满幅且不透明**，而品牌画稿（assets/moneyfly-logo.svg：黑色圆角
  方块 + 品牌蓝 M）在 macOS 上是以「四周留白 + 圆角透明」的形式呈现的，
  直接缩放会出现黑角/留白。

做法（与 Android 的呈现约定对齐，已用像素比例验证）：
1. 取 macos 的 1024 画稿（仓库里该画稿最高分辨率的位图版本）；
2. 裁掉透明留白 → 得到画稿本体；
3. 按 alpha 合成到**不透明黑底**（画稿自身背景色 #000000）→ 满幅；
4. 按 Contents.json 要求的 19 个尺寸缩放，输出**无 alpha 通道**的 PNG。

自检：把生成的图标与 Android 的 ic_launcher 做蓝色标记占比比对（应当一致，
因为 Android 就是同一画稿裁白后满幅的版本）。

用法： python3 tool/gen_ios_icons.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png'
ANDROID_REF = ROOT / 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png'
ICONSET = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
CONTENTS = ICONSET / 'Contents.json'


def blue_ratio(im: Image.Image, alpha_min: int = 200) -> float:
    """蓝色标记占画布宽度比例（与画布尺寸无关，可比对不同分辨率）。"""
    im = im.convert('RGBA')
    w, h = im.size
    xs = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = im.getpixel((x, y))
            if a >= alpha_min and b > 120 and b - r > 40:
                xs.append(x)
    if not xs:
        return 0.0
    return (max(xs) - min(xs) + 1) / w


def build_master() -> Image.Image:
    src = Image.open(SRC).convert('RGBA')
    bbox = src.getbbox()
    if bbox is None:
        sys.exit(f'✗ {SRC} 全透明，无法使用')
    art = src.crop(bbox)
    # 合成到不透明黑底：画稿背景就是 #000000，填满后与 Android 呈现一致，
    # 且满足 iOS「图标不得含 alpha 通道」的要求
    canvas = Image.new('RGB', art.size, (0, 0, 0))
    canvas.paste(art, mask=art.split()[3])
    print(f'· 画稿本体 {art.size[0]}x{art.size[1]}（原图 {src.size[0]}x{src.size[1]}，裁掉透明留白）')
    return canvas


def main() -> int:
    if not SRC.exists():
        sys.exit(f'✗ 找不到画稿 {SRC}')
    if not CONTENTS.exists():
        sys.exit(f'✗ 找不到 {CONTENTS}')

    master = build_master()
    spec = json.loads(CONTENTS.read_text(encoding='utf-8'))

    made = 0
    for entry in spec['images']:
        name = entry.get('filename')
        size = entry.get('size')
        scale = entry.get('scale')
        if not name or not size or not scale:
            continue
        base = float(size.split('x')[0])
        mult = int(scale.rstrip('x'))
        px = round(base * mult)
        icon = master.resize((px, px), Image.LANCZOS)
        # 关键：转 RGB（无 alpha 通道）—— iOS 图标带 alpha 会被系统视为无效
        icon.save(ICONSET / name, format='PNG', optimize=True)
        made += 1
        print(f'  ✓ {name:34s} {px}x{px}')

    print(f'· 共生成 {made} 个图标')

    # ---- 自检：与 Android 呈现一致性 ----
    ref = Image.open(ANDROID_REF).convert('RGBA') if ANDROID_REF.exists() else None
    ours = Image.open(ICONSET / 'Icon-App-1024x1024@1x.png').convert('RGBA')
    r_our = blue_ratio(ours)
    print(f'\n一致性自检（品牌蓝标记占画布宽度）:')
    print(f'  本次生成 iOS : {r_our:.1%}')
    if ref is not None:
        r_ref = blue_ratio(ref)
        print(f'  Android 现有 : {r_ref:.1%}')
        delta = abs(r_our - r_ref)
        print(f'  偏差         : {delta:.1%}')
        if delta > 0.03:
            print('  ⚠ 偏差偏大（>3%），请人工确认画稿是否同一版本', file=sys.stderr)
            return 1
        print('  ✓ 与 Android 一致')
    # 无 alpha 校验
    for f in ICONSET.glob('Icon-App-*.png'):
        im = Image.open(f)
        if im.mode != 'RGB':
            print(f'  ⚠ {f.name} 模式为 {im.mode}（应为 RGB 无 alpha）', file=sys.stderr)
            return 1
    print('  ✓ 全部图标均无 alpha 通道')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
