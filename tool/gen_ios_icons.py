#!/usr/bin/env python3
"""生成 iOS App 图标（AppIcon.appiconset），与各桌面端共用同一张透明画稿。

背景（2026-10 产品改版）：品牌图标改成「只有带颜色的 M、背景透明」的单一标记，
不再有黑色圆角底板。唯一真源是 `assets/icon-mark.png`（1024×1024 RGBA 透明底），
因此 iOS 图标直接按 Contents.json 的 19 个尺寸等比缩放即可，不需要再裁白/铺黑底。

关于 alpha：App Store 要求 App 图标**不带 alpha**；本项目走**侧载 IPA**分发，
按产品要求保留透明底。若将来上架 App Store，需要另出一套不透明底版本
（把本脚本输出的 RGBA 合成到纯色底即可）。

自检：把生成的 1024 与 Android 的 ic_launcher 做「标记占画布宽度」比对
（两者同源同比例，应当一致）。

用法： python3 tool/gen_ios_icons.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'assets/icon-mark.png'
ANDROID_REF = ROOT / 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png'
ICONSET = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
CONTENTS = ICONSET / 'Contents.json'


def mark_ratio(im: Image.Image, alpha_min: int = 200, lum_min: int = 60) -> float:
    """标记（不透明且非黑）占画布宽度比例，与画布尺寸无关，可跨分辨率比对。"""
    im = im.convert('RGBA')
    w, h = im.size
    xs = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = im.getpixel((x, y))
            if a >= alpha_min and max(r, g, b) > lum_min:
                xs.append(x)
    if not xs:
        return 0.0
    return (max(xs) - min(xs) + 1) / w


def main() -> int:
    if not SRC.exists():
        sys.exit(f'✗ 找不到画稿 {SRC}')
    if not CONTENTS.exists():
        sys.exit(f'✗ 找不到 {CONTENTS}')

    master = Image.open(SRC).convert('RGBA')
    if master.size != (1024, 1024):
        master = master.resize((1024, 1024), Image.LANCZOS)
    spec = json.loads(CONTENTS.read_text(encoding='utf-8'))

    made = 0
    for entry in spec['images']:
        name, size, scale = entry.get('filename'), entry.get('size'), entry.get('scale')
        if not (name and size and scale):
            continue
        base = float(size.split('x')[0])
        px = round(base * int(scale.rstrip('x')))
        master.resize((px, px), Image.LANCZOS).save(ICONSET / name, format='PNG', optimize=True)
        made += 1
        print(f'  ✓ {name:34s} {px}x{px}')
    print(f'· 共生成 {made} 个图标')

    # ---- 自检：与 Android 同源一致性 ----
    ours = Image.open(ICONSET / 'Icon-App-1024x1024@1x.png').convert('RGBA')
    r_our = mark_ratio(ours)
    print('\n一致性自检（标记占画布宽度）:')
    print(f'  本次生成 iOS : {r_our:.1%}')
    if ANDROID_REF.exists():
        r_ref = mark_ratio(Image.open(ANDROID_REF))
        print(f'  Android 现有 : {r_ref:.1%}')
        delta = abs(r_our - r_ref)
        print(f'  偏差         : {delta:.1%}')
        if delta > 0.03:
            print('  ⚠ 偏差偏大（>3%），请人工确认画稿是否同一版本', file=sys.stderr)
            return 1
        print('  ✓ 与 Android 一致')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
