#!/usr/bin/env python3
"""Generate platform icons from the approved DeskBar SVG using the pinned Tauri CLI."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "apps/desktop"
ICONS = DESKTOP / "src-tauri/icons"
RES = ROOT / "apps/android/android/app/src/main/res"
SOURCE = ROOT / "assets/brand/deskbar.svg"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def render(source, destination, sizes=()):
    subprocess.run(
        ["pnpm", "exec", "tauri", "icon", str(source), "--output", str(destination)]
        + [argument for size in sizes for argument in ("--png", str(size))],
        cwd=DESKTOP,
        check=True,
    )


def main():
    path = ET.parse(SOURCE).getroot().find("{http://www.w3.org/2000/svg}path")
    shape = f'<path d="{path.attrib["d"]}" fill="{path.attrib["fill"]}"/>'
    # Center the SVG canvas, preserving its rightward optical offset.
    # An inset, rounded silver tile leaves room for macOS icon spacing.
    desktop = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">\n'
        '  <rect x="32" y="32" width="448" height="448" rx="100" fill="#F6F7F9"/>\n'
        f'  <g transform="translate(64 64) scale(4)">{shape}</g>\n</svg>\n'
    )
    write(ICONS / "icon.svg", desktop)
    with tempfile.TemporaryDirectory(prefix="deskbar-icons-") as directory:
        temporary = Path(directory)
        render(ICONS / "icon.svg", temporary / "desktop")
        for name in ("32x32.png", "64x64.png", "128x128.png", "128x128@2x.png", "icon.png", "icon.icns", "icon.ico"):
            shutil.copyfile(temporary / "desktop" / name, ICONS / name)

        render(SOURCE, temporary / "tray", (22,))
        shutil.copyfile(temporary / "tray/22x22.png", ICONS / "tray.png")

        # Legacy launchers receive a tile; adaptive launchers apply their own mask.
        legacy = temporary / "android.svg"
        write(legacy, '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">'
              '<rect width="96" height="96" rx="22" fill="#F6F7F9"/>'
              f'<g transform="translate(9.6 9.6) scale(.8)">{shape}</g></svg>\n')
        render(legacy, temporary / "android", (48, 72, 96, 144, 192))
        for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
            shutil.copyfile(temporary / f"android/{size}x{size}.png", RES / f"mipmap-{density}/ic_launcher.png")

    foreground = (
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">\n'
        '    <group android:scaleX="0.8" android:scaleY="0.8" android:translateX="15.6" android:translateY="15.6">\n'
        f'        <path android:fillColor="{path.attrib["fill"]}" android:pathData="{path.attrib["d"]}"/>\n'
        '    </group>\n</vector>\n'
    )
    write(RES / "drawable/ic_launcher_foreground.xml", foreground)
    for version in (26, 33):
        monochrome = '    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n' if version == 33 else ""
        write(RES / f"mipmap-anydpi-v{version}/ic_launcher.xml",
              '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
              '    <background android:drawable="@color/deskbar_icon_background"/>\n'
              '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
              + monochrome + '</adaptive-icon>\n')


if __name__ == "__main__":
    main()
