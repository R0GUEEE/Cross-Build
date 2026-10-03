#!/usr/bin/env python3
"""Generates a placeholder 1024x1024 AppIcon.png. Run once; not part of CI."""
from PIL import Image, ImageDraw, ImageFont

size = 1024
img = Image.new("RGB", (size, size), "#1C1C1E")
draw = ImageDraw.Draw(img)

accent = "#3A7CFF"
draw.polygon([(0, size), (size * 0.62, 0), (size, 0), (size, size * 0.1), (size * 0.1, size)], fill=accent)

text = "CB"
font_path = "/usr/lib/ruby/3.3.0/rdoc/generator/template/darkfish/fonts/SourceCodePro-Bold.ttf"
font = ImageFont.truetype(font_path, 460)
assert not isinstance(font, ImageFont.ImageFont), "truetype font failed to load, got bitmap fallback"

bbox = draw.textbbox((0, 0), text, font=font)
w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
draw.text(((size - w) / 2 - bbox[0], (size - h) / 2 - bbox[1]), text, fill="#F5F5F7", font=font)

img.save("AppIcon.png")
print("wrote AppIcon.png", img.size)
