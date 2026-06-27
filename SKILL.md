---
name: image-to-code
description: Extract structured data (colors, layout, OCR text) from images without AI vision. Supports macOS, Linux, Windows. Trigger with "analyze image", "read image", "extract text", "OCR".
---

# image-to-code

Extract structured data from images using Tesseract OCR + Pillow. No AI vision required.

## Requirements

- Python 3.10+
- Tesseract OCR engine (`tesseract` on PATH)
- Thai language data (auto-downloaded on first OCR use)

## Installation

```bash
# NPX (easiest — auto-installs Python deps)
npx image-to-code path/to/image.png

# Pip
pip install image-to-code
image-to-code path/to/image.png
```

Or from source:

```bash
git clone https://github.com/phumitchreal/image-to-code.git
cd image-to-code
pip install -r requirements.txt
python -m image_to_code.analyze path/to/image.png
```

### Prerequisites

Install Tesseract OCR:
- macOS: `brew install tesseract tesseract-lang`
- Linux: `sudo apt install tesseract-ocr tesseract-ocr-tha`
- Windows: `winget install -e --id UB-Mannheim.TesseractOCR`

## Usage

### Analyze an image
```bash
python -m image_to_code.analyze path/to/image.png
python -m image_to_code.analyze path/to/image.png --json     # JSON only
python -m image_to_code.analyze path/to/image.png --full     # Report + JSON
python -m image_to_code.analyze --clipboard                  # From clipboard
python -m image_to_code.analyze path/to/image.png --lang eng --min-confidence 80
```

### Or import as a library
```python
from image_to_code.colors import extract_colors
from image_to_code.layout import detect_layout
from image_to_code.ocr import extract_text

colors = extract_colors("image.png")
layout = detect_layout("image.png")
text = extract_text("image.png", language="tha+eng", min_confidence=70)
```

## Output Structure

The JSON output contains:
- `imageType`: "photo" or "ui"
- `colors`: background, text, button, border, palette, gradient, harmony, contrast ratio
- `layout`: type (mobile/desktop), sections, columns, components (with hero-padding detection)
- `text`: OCR words with bounding boxes, full text, by-zone text, button annotations
- `css`: CSS custom property recommendations
