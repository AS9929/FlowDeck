#!/usr/bin/env python3
"""将原始国旗 SVG 离线渲染为完整 PNG，避开 Asset Catalog 对 use/clipPath 的兼容问题。

开发机需要 librsvg 的 rsvg-convert；App 不引入运行时依赖。源图及其许可证保留，
每次从项目根目录运行本脚本即可重建 64 × 48 pt、3x 的国旗资源。
"""

import json
import shutil
import subprocess
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    renderer = shutil.which("rsvg-convert")
    if not renderer:
        raise SystemExit("请先安装 librsvg，确保 rsvg-convert 位于 PATH 中。")

    sources = sorted((root / "DesignResources/Flags").glob("*.svg"))
    assets = root / "FlowDeck/Resources/Assets.xcassets/RegionIcons"
    for source in sources:
        folder = assets / ("Region-" + source.stem + ".imageset")
        folder.mkdir(parents=True, exist_ok=True)
        temporary = folder / "flag.pending.png"
        subprocess.run(
            [renderer, "--width", "192", "--height", "144", "--keep-aspect-ratio",
             "--output", str(temporary), str(source)],
            check=True,
        )
        temporary.replace(folder / "flag.png")
        contents = {
            "images": [{"filename": "flag.png", "idiom": "universal", "scale": "3x"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "original"},
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
        # 原 SVG 已保留在 DesignResources；不要让 actool 编译不支持的路径引用。
        old_svg = folder / "flag.svg"
        if old_svg.exists():
            old_svg.unlink()

    print("已生成 {} 份完整国旗资源".format(len(sources)))


if __name__ == "__main__":
    main()
