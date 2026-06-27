"""Shared utilities: hex/rgb conversion, luminance, contrast, Thai merging."""

import re


def hex_to_rgb(hex_str):
    r = int(hex_str[1:3], 16)
    g = int(hex_str[3:5], 16)
    b = int(hex_str[5:7], 16)
    return r, g, b


def rgb_to_hex(r, g, b):
    return f"#{r:02X}{g:02X}{b:02X}"


def luminance(r, g, b):
    return 0.299 * r + 0.587 * g + 0.114 * b


def contrast_ratio(lum1, lum2):
    l1 = max(lum1, lum2) + 0.05
    l2 = min(lum1, lum2) + 0.05
    return l1 / l2


def saturation(r, g, b):
    max_c = max(r, g, b)
    min_c = min(r, g, b)
    if max_c == 0:
        return 0
    return (max_c - min_c) / max_c * 100


def merge_thai_text(text):
    """Merge Thai grapheme clusters split by Tesseract into correct words."""
    if not text:
        return text
    return re.sub(r"(?<=[\u0E00-\u0E7F])\s+(?=[\u0E00-\u0E7F])", "", text)
