#!/usr/bin/env python3
"""Render the existing DeepClub pixel SVG into iOS assets, without generated art."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def polygon(data: str) -> list[tuple[int, int]]:
    # The owned mark contains only integer M/H/V/Z commands. Fail if it changes.
    tokens = re.findall(r"[MHVZ]|-?\d+", data)
    if "".join(tokens) != re.sub(r"\s+", "", data):
        raise ValueError("The symbol contains unsupported path commands.")
    points = []
    index = 0
    x = y = 0
    while index < len(tokens):
        command = tokens[index]
        index += 1
        if command == "Z":
            break
        if command == "M":
            x, y = int(tokens[index]), int(tokens[index + 1])
            index += 2
        elif command == "H":
            x = int(tokens[index])
            index += 1
        elif command == "V":
            y = int(tokens[index])
            index += 1
        else:
            raise ValueError(f"Unexpected path token: {command}")
        points.append((x, y))
    return points


def save_catalog(directory: Path, images: list[dict], *, vector: bool = False):
    directory.mkdir(parents=True, exist_ok=True)
    value = {"images": images, "info": {"author": "DeepClub", "version": 1}}
    if vector:
        value["properties"] = {"preserves-vector-representation": True,
                               "template-rendering-intent": "original"}
    (directory / "Contents.json").write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    args = parser.parse_args()
    source = args.checkout.resolve()
    if not (source / "DeepSeekHarnessMobile/Resources/Info.plist").is_file():
        raise SystemExit("This is not an iOS source checkout.")
    symbol = (ROOT / "brand/symbol-color.svg").read_text()
    dark_symbol = symbol.replace('#29292D', '#F4F4F5')
    paths = [(polygon(path.attrib["d"]), path.attrib["fill"])
             for path in ET.fromstring(symbol).findall("{http://www.w3.org/2000/svg}path")]
    if len(paths) != 2:
        raise SystemExit("Expected exactly two owned pixel paths.")

    for catalog in [source / "DeepSeekHarnessMobile/Resources/Assets.xcassets",
                    source / "AgentLiveActivityWidget/Assets.xcassets"]:
        mark = catalog / "DeepClubMark.imageset"
        save_catalog(mark, [
            {"filename": "deepclub-symbol.svg", "idiom": "universal"},
            {"filename": "deepclub-symbol-dark.svg", "idiom": "universal",
             "appearances": [{"appearance": "luminosity", "value": "dark"}]}], vector=True)
        (mark / "deepclub-symbol.svg").write_text(symbol)
        (mark / "deepclub-symbol-dark.svg").write_text(dark_symbol)

    icon = source / "DeepSeekHarnessMobile/Resources/Assets.xcassets/AppIcon.appiconset"
    save_catalog(icon, [
        {"filename": "AppIcon-light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"filename": "AppIcon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
         "appearances": [{"appearance": "luminosity", "value": "dark"}]}])
    # Integral 24 px modules preserve the original pixel edges at 1024 px.
    for name, background, foreground in [("AppIcon-light.png", "#F4F4F5", None),
                                         ("AppIcon-dark.png", "#18181B", "#F4F4F5")]:
        image = Image.new("RGB", (1024, 1024), background)
        draw = ImageDraw.Draw(image)
        for points, color in paths:
            fill = foreground if color == "#29292D" and foreground else color
            draw.polygon([(128 + 24 * x, 128 + 24 * y) for x, y in points], fill=fill)
        image.save(icon / name, format="PNG", optimize=True)

    action = source / "ActionExtension/Assets.xcassets/ActionIcon.appiconset"
    save_catalog(action, [{"filename": "ActionIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}])
    # System Action icons use only the glyph alpha; black pixels avoid a solid tile.
    image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for points, _ in paths:
        draw.polygon([(128 + 24 * x, 128 + 24 * y) for x, y in points], fill=(0, 0, 0, 255))
    image.save(action / "ActionIcon.png", format="PNG", optimize=True)
    print("Rendered DeepClub vector marks, light/dark pixel app icons and Action icon.")


if __name__ == "__main__":
    main()
