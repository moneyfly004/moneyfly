#!/usr/bin/env python3
"""把图标里的品牌蓝（#455FE9 及其抗锯齿过渡色）替换成白色，生成「黑底白标」的单色图标。

为什么需要：产品要求 App 图标与首页左上角图标为白色单色标。
做法：只改「偏蓝」的像素（蓝通道明显高于红/绿），按原像素亮度映射成等亮灰阶，
保留抗锯齿边缘与 alpha；黑色底、透明区域完全不动 —— 因此不会破坏 iOS 的
「图标不得带透明」要求，也不会改动 Layout/尺寸。

用法：python3 tool/make_white_icons.py
"""
from PIL import Image
import glob, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 需要处理的位图
TARGETS_PNG = [
    'assets/moneyfly-logo.png',
    'android/app/src/main/res/mipmap-*/ic_launcher.png',
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png',
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png',
    'web/icons/*.png',
    'web/favicon.png',
]
TARGETS_ICO = [
    'assets/tray_icon.ico',
    'windows/runner/resources/app_icon.ico',
]


def is_blue(r: int, g: int, b: int) -> bool:
    """品牌蓝 #455FE9 = (69,95,233)：蓝通道显著高于红/绿即视为蓝系（含抗锯齿过渡）。"""
    return b > 80 and b > r + 25 and b > g + 25


def whiten(img: Image.Image):
    """把蓝系像素改成等亮度灰阶（=白标）。返回 (新图, 改动像素数)。"""
    out = img.convert('RGBA')
    px = out.load()
    w, h = img.size
    n = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0 or not is_blue(r, g, b):
                continue
            # 按蓝通道占比映射到 0..255 白：纯品牌蓝→纯白(255)，抗锯齿边缘→按比例变灰，
            # 既保证「标是白色」又保留边缘平滑
            lum = max(0, min(255, round(255 * (b / 233.0))))
            px[x, y] = (lum, lum, lum, a)
            n += 1
    return out, n


def main() -> None:
    total = 0
    for pattern in TARGETS_PNG:
        for path in glob.glob(os.path.join(ROOT, pattern)):
            src = Image.open(path)
            had_alpha = src.mode in ('RGBA', 'LA') or 'transparency' in src.info
            img, n = whiten(src)
            if n:
                # iOS/App Store 要求图标不带 alpha：原图无 alpha 的继续输出 RGB
                out = img if had_alpha else img.convert('RGB')
                out.save(path, optimize=True)
                total += n
                print(f'  ✓ {os.path.relpath(path, ROOT)}  ({n} px)')
    for rel in TARGETS_ICO:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        src = Image.open(path)
        sizes = sorted(getattr(src, 'ico').sizes()) if hasattr(src, 'ico') else [(256, 256)]
        biggest = max(sizes, key=lambda t: t[0] * t[1])
        base = src.ico.getimage(biggest) if hasattr(src, 'ico') else src
        out, n = whiten(base)
        if n:
            # 用白化后的最大帧重建多尺寸 ico（PIL 会按 sizes 缩放各档）
            out.save(path, format='ICO', sizes=sizes)
            total += n
            print(f'  ✓ {rel}  ({n} px, sizes={sizes})')
    print(f'完成：共改动 {total} 个像素')


if __name__ == '__main__':
    main()
