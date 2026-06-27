# image-to-code

> Extract structured data (colors, layout, OCR text) from images. **No AI vision required.**  
> Cross-platform: macOS · Linux · Windows  
> Uses Tesseract OCR + Pillow for fully programmatic analysis.

## Features

- **Color Extraction** — dominant colors, semantic role detection (background, text, button, border, surface), WCAG contrast ratio, color harmony classification, gradient detection
- **Layout Detection** — horizontal section segmentation, vertical column detection, component labeling with hero-padding awareness
- **OCR Text Extraction** — multi-PSM scanning, histogram stretch + adaptive threshold preprocessing, footer/branding crop scans, Thai grapheme cluster merging, intelligent dedup
- **Button Detection** — heuristic-based UI button identification from bounding box sizes
- **Photo/UI Classification** — classifies images as photo (organic background) vs UI (flat/schematic) using luminance variance + edge ratio heuristics
- **CSS Output** — generates CSS custom properties and media query recommendations
- **Clipboard Support** — read directly from clipboard (`--clipboard` flag)

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| Python | 3.10+ | Core runtime |
| [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) | 5.x | OCR engine (must be on PATH) |
| [Pillow](https://python-pillow.org/) | 10.0+ | Image processing |
| [pytesseract](https://github.com/madmaze/pytesseract) | 0.3.10+ | Python Tesseract wrapper |

### Install Tesseract

```bash
# macOS
brew install tesseract tesseract-lang

# Linux (Ubuntu/Debian)
sudo apt install tesseract-ocr tesseract-ocr-tha tesseract-ocr-osd

# Linux (Arch)
sudo pacman -S tesseract tesseract-data-tha

# Windows
winget install -e --id UB-Mannheim.TesseractOCR
# Or download from https://github.com/UB-Mannheim/tesseract/wiki
```

## Installation

```bash
# Clone
git clone https://github.com/phumitchreal/image-to-code.git
cd image-to-code

# Install Python dependencies
pip install -r requirements.txt

# Verify Tesseract is on PATH
tesseract --version
```

## Usage

### CLI

```bash
# Basic analysis
python -m image_to_code.analyze screenshot.png

# JSON output only
python -m image_to_code.analyze screenshot.png --json

# Full report + JSON
python -m image_to_code.analyze screenshot.png --full

# Read from clipboard
python -m image_to_code.analyze --clipboard

# Specify language and confidence threshold
python -m image_to_code.analyze screenshot.png --lang eng --min-confidence 80

# Custom color sampling
python -m image_to_code.analyze screenshot.png --sample-count 3000 --quantize-tolerance 20
```

### Python Library

```python
from image_to_code import analyze

# Full analysis pipeline
result = analyze.analyze_image("screenshot.png")

# Or use individual modules
from image_to_code.colors import extract_colors
from image_to_code.layout import detect_layout
from image_to_code.ocr import extract_text

colors = extract_colors("image.png")
layout = detect_layout("image.png")
text = extract_text("image.png", language="tha+eng", min_confidence=70)

print(f"Background: {colors['background']}")
print(f"Text: {colors['text']} (contrast: {colors['contrastRatio']}:1)")
print(f"Layout: {layout['layoutType']}")
print(f"OCR: {text['rawText']}")
```

## Output Example

```
=======================================================================
  IMAGE ANALYSIS REPORT
=======================================================================

Image: 1913x995 (landscape/desktop, photo)

--- Colors ---
  Background: #0F0F0F
  Surfaces:   #1E1E1E, #000000, #2D2D1E
  Text:       #FFFFFF  (contrast: 16.9:1)
  Button:     #5A69F0
  Border:     #2D1E1E
  Harmony:    neutral
  Palette:    20 unique colors

--- Layout Components ---
  hero-padding     y= 0% h=45%  color=#282828
  bottom-segment   y=45% h=53%  color=#141414
  bottom-segment   y=98% h= 2%  color=#000000

--- OCR Text (35 words >=70%) ---
DISCORD COMMUNITY HUB
ติดตามสมาชิกแก๊งแบบเรียลไทม์และดูพาร์ทเนอร์ที่ร่วมงานกับเรา
Gang Partners

--- UI Buttons (2) ---
  [button] Gang  (z=middle, y=570, c=94.4%)
  [button] Partners  (z=middle, y=580, c=96.6%)

--- CSS Recommendations ---
  --bg: #0F0F0F
  --surface: #1E1E1E
  --text: #FFFFFF
  --primary: #5A69F0
  --border: #2D1E1E
  --radius: 6px

=======================================================================
```

## JSON Output Structure

```json
{
  "imageType": "photo",
  "image": { "width": 1913, "height": 995 },
  "colors": {
    "background": "#0F0F0F",
    "text": "#FFFFFF",
    "button": "#5A69F0",
    "border": "#2D1E1E",
    "contrastRatio": 16.9,
    "harmony": "neutral",
    "palette": [ ... ],
    "gradient": null
  },
  "layout": {
    "type": "landscape/desktop",
    "components": [ ... ]
  },
  "text": {
    "words": 35,
    "boxes": [ ... ],
    "buttons": [ ... ],
    "fullText": "...",
    "byZone": { "top": "...", "middle": "...", "bottom": "..." }
  },
  "css": {
    "customProperties": {
      "--bg": "#0F0F0F",
      "--text": "#FFFFFF",
      "--primary": "#5A69F0"
    }
  }
}
```

## PowerShell Version (Windows)

The `powershell/` directory contains the original Windows PowerShell scripts. These work on Windows only (require `System.Drawing`). Usage:

```powershell
# Full analysis
.\powershell\analyze-image.ps1 -ImagePath screenshot.png -Full

# From clipboard
.\powershell\analyze-image.ps1 -Clipboard

# JSON output
.\powershell\analyze-image.ps1 -ImagePath screenshot.png -Json
```

## How It Works

### Photo vs UI Classification
Uses three heuristics on a coarse pixel sample:
1. **Distinct color count** — photos have >50 distinct colors (after 4-bit quantization)
2. **Luminance IQR** — photos have narrow interquartile range (<80) with moderate color count
3. **Edge ratio** — photos have low edge ratio (<0.3) on adjacent spatial samples with wide luminance range

### Thai Text Handling
Tesseract splits Thai characters into individual grapheme components. The `merge_thai_text()` post-processor removes spaces between Thai Unicode characters (U+0E00–U+0E7F) to reconstruct correct words.

### Adaptive Thresholding
For photo backgrounds, two preprocessing passes run:
1. Histogram stretch (full contrast enhancement)
2. Adaptive threshold (hard clip at 100/160 luminance)

OCR runs on all versions (original + preprocessed) with multiple PSM modes and deduplicates results.

## License

MIT
