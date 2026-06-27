"""Main orchestrator: runs color, layout, and OCR analysis, produces combined JSON/CSS report."""

import argparse
import json
import sys
import os
import tempfile
from PIL import Image, ImageGrab

from .colors import extract_colors
from .layout import detect_layout
from .ocr import extract_text


def analyze_image(image_path=None, clipboard=False, ocr_language="tha+eng",
                  min_confidence=70, sample_count=2000, quantize_tolerance=15,
                  full=False, json_output=False):
    """Run full analysis pipeline on an image."""
    resolved_path = image_path

    if clipboard:
        try:
            clip_img = ImageGrab.grabclipboard()
            if clip_img is None:
                print("Error: No image found in clipboard", file=sys.stderr)
                sys.exit(1)
            temp_dir = os.path.join(tempfile.gettempdir(), "image-to-code")
            os.makedirs(temp_dir, exist_ok=True)
            save_path = os.path.join(temp_dir, f"clipboard_{os.urandom(4).hex()}.png")
            clip_img.save(save_path)
            resolved_path = save_path
            print(f"\n[Clipboard image saved to: {save_path}]")
        except Exception as e:
            print(f"Error reading clipboard: {e}", file=sys.stderr)
            sys.exit(1)

    if not resolved_path or not os.path.exists(resolved_path):
        print("Error: Image path does not exist", file=sys.stderr)
        sys.exit(1)

    print("Analyzing image...", file=sys.stderr)

    colors = extract_colors(resolved_path, sample_count, quantize_tolerance)
    is_photo = colors.get("isPhoto", False)

    layout = detect_layout(resolved_path)
    layout_type = layout.get("layoutType", "unknown")

    ocr_result = extract_text(resolved_path, ocr_language, min_confidence)
    ocr_boxes = ocr_result.get("boxes", [])
    ocr_raw_text = ocr_result.get("rawText", "")
    ocr_by_zone = ocr_result.get("byZone", {})

    w = colors.get("imageWidth", 0)
    h = colors.get("imageHeight", 0)
    radius_val = "8px" if "mobile" in layout_type else "6px"
    vp_val = "width=device-width, initial-scale=1.0" if w <= 430 else ""
    mq_val = "mobile" if w <= 430 else ("tablet" if w <= 768 else "desktop")

    # Button detection: large boxes in lower area
    buttons = []
    search_top = h * 0.25 if h else 0
    for box in ocr_boxes:
        if box.get("w", 0) > 30 and box.get("h", 0) > 20 and box.get("conf", 0) > 80 and box.get("y", 0) > search_top:
            buttons.append({
                "text": box.get("text", ""),
                "x": box.get("x", 0),
                "y": box.get("y", 0),
                "w": box.get("w", 0),
                "h": box.get("h", 0),
                "zone": box.get("zone", ""),
                "conf": box.get("conf", 0),
            })

    gradient_info = colors.get("gradient")
    palette_data = colors.get("palette", [])
    surface_list = colors.get("surfaces", [])
    border_color = colors.get("border")

    result = {
        "imageType": "photo" if is_photo else "ui",
        "image": {
            "path": resolved_path,
            "width": w,
            "height": h,
            "aspect": round(w / h, 3) if h else 0,
        },
        "colors": {
            "background": colors.get("background", "#FFFFFF"),
            "text": colors.get("text", "#1F2937"),
            "accent": colors.get("button", "#4F46E5"),
            "border": border_color if border_color else "#E5E7EB",
            "palette": palette_data,
            "surfaces": surface_list,
            "button": colors.get("button"),
            "textSecondary": colors.get("textSecondary"),
            "contrastRatio": colors.get("contrastRatio", 0),
            "harmony": colors.get("harmony", ""),
            "gradient": gradient_info,
        },
        "layout": {
            "type": layout_type,
            "sections": layout.get("sections", []),
            "columns": layout.get("columns", []),
            "components": layout.get("components", []),
        },
        "text": {
            "words": ocr_result.get("words", 0),
            "boxes": ocr_boxes,
            "buttons": buttons,
            "fullText": ocr_raw_text,
            "byZone": ocr_by_zone,
        },
        "css": {
            "customProperties": {
                "--bg": colors.get("background", "#FFFFFF"),
                "--surface": surface_list[0] if surface_list else colors.get("background", "#FFFFFF"),
                "--text": colors.get("text", "#1F2937"),
                "--primary": colors.get("button", "#4F46E5"),
                "--border": border_color if border_color else "#E5E7EB",
                "--radius": radius_val,
            },
            "surfaces": surface_list,
            "harmony": colors.get("harmony", ""),
            "contrastRatio": colors.get("contrastRatio", 0),
            "gradient": gradient_info,
            "viewport": vp_val,
            "mediaQuery": mq_val,
        },
    }

    if json_output or full:
        print(json.dumps(result, indent=2, ensure_ascii=False))

    if not json_output:
        print()
        print("=" * 72)
        print("  IMAGE ANALYSIS REPORT")
        print("=" * 72)
        print()
        print(f"Image: {w}x{h} ({layout_type}, {'photo' if is_photo else 'UI'})")
        print()
        print("--- Colors ---")
        print(f"  Background: {colors.get('background', '')}")
        print(f"  Surfaces:   {', '.join(str(s) for s in surface_list)}")
        print(f"  Text:       {colors.get('text', '')}  (contrast: {colors.get('contrastRatio', 0)}:1)")
        if colors.get("textSecondary"):
            print(f"  Text(2nd):  {colors['textSecondary']}")
        print(f"  Button:     {colors.get('button', '')}")
        print(f"  Border:     {colors.get('border', '')}")
        print(f"  Harmony:    {colors.get('harmony', '')}")
        print(f"  Palette:    {len(palette_data)} unique colors")
        print()
        print("--- Layout Components ---")
        for c in layout.get("components", []):
            print(f"  {c.get('type', ''):16} y={c.get('y_pct', 0):2}% h={c.get('h_pct', 0):2}%  color={c.get('color', '')}")
        print()
        print(f"--- OCR Text ({ocr_result.get('words', 0)} words >= {min_confidence}%) ---")
        if ocr_raw_text:
            print(ocr_raw_text)
        else:
            print(f"  [top]    {ocr_by_zone.get('top', '')}")
            print(f"  [middle] {ocr_by_zone.get('middle', '')}")
            print(f"  [bottom] {ocr_by_zone.get('bottom', '')}")
        print()

        if buttons:
            print(f"--- UI Buttons ({len(buttons)}) ---")
            for b in buttons:
                print(f"  [button] {b.get('text', '')}  (z={b.get('zone', '')}, y={b.get('y', 0)}, c={b.get('conf', 0)}%)")
            print()

        print("--- CSS Recommendations ---")
        for key, val in result["css"]["customProperties"].items():
            print(f"  {key}: {val}")
        if gradient_info:
            g = gradient_info
            print(f"  gradient: {g.get('type', '')} {' -> '.join(str(c) for c in g.get('colors', []))}")
        print()
        print("=" * 72)

    if full:
        print()
        print("=== Full JSON Output ===")
        print(json.dumps(result, indent=2, ensure_ascii=False))

    # Clipboard temp cleanup
    if clipboard and os.path.exists(resolved_path):
        try:
            os.remove(resolved_path)
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Image-to-Code: Extract structured data from images")
    parser.add_argument("image_path", nargs="?", help="Path to image file")
    parser.add_argument("--clipboard", "-c", action="store_true", help="Read image from clipboard")
    parser.add_argument("--lang", "-l", default="tha+eng", help="Tesseract language (default: tha+eng)")
    parser.add_argument("--min-confidence", "-m", type=int, default=70, help="Minimum OCR confidence (default: 70)")
    parser.add_argument("--sample-count", type=int, default=2000, help="Color sample count (default: 2000)")
    parser.add_argument("--quantize-tolerance", type=int, default=15, help="Color quantize tolerance (default: 15)")
    parser.add_argument("--full", "-f", action="store_true", help="Show full JSON output")
    parser.add_argument("--json", "-j", action="store_true", help="Output JSON only")
    args = parser.parse_args()

    if not args.image_path and not args.clipboard:
        parser.print_help()
        sys.exit(1)

    analyze_image(
        image_path=args.image_path,
        clipboard=args.clipboard,
        ocr_language=args.lang,
        min_confidence=args.min_confidence,
        sample_count=args.sample_count,
        quantize_tolerance=args.quantize_tolerance,
        full=args.full,
        json_output=args.json,
    )


if __name__ == "__main__":
    main()
