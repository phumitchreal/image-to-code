---
name: image-to-code
description: >
  Extract colors, layout, OCR text from images. 100% programmatic — no AI vision needed.
  Auto-installed via npm. Works with opencode, Claude Code, Cursor, Windsurf, and other AI agents.
  Trigger when user asks to analyze/read/OCR any image file or clipboard screenshot.
---

# image-to-code — AI Agent Skill

Extract structured data from images using Tesseract OCR + Pillow.
Supports Thai + English, UI button detection, hero-padding, color harmony, CSS generation.

## Quick Install

```bash
npx image-to-code screenshot.png
# Or globally:
npm install -g image-to-code
image-to-code screenshot.png
```

## Usage for AI Agents

When the user provides an image or asks to analyze one:

### 1. Run analysis (always run this first):
```bash
npx image-to-code image.png
```

### 2. Get structured JSON (for machine processing):
```bash
npx image-to-code image.png --json
```

### 3. Get full report + JSON:
```bash
npx image-to-code image.png --full
```

### 4. From clipboard:
```bash
npx image-to-code --clipboard
```

### 5. Custom OCR language or confidence:
```bash
npx image-to-code image.png --lang eng --min-confidence 80
```

## Output You Can Expect

The JSON contains:
- `imageType`: `"photo"` or `"ui"`
- `colors`: background (#0F0F0F), text (#FFFFFF), button (#5A69F0), border, palette (20 colors), contrast ratio, harmony type
- `layout`: type (mobile/desktop), sections (y%, h%, color), components (hero-padding, bottom-segment)
- `text`: OCR words with bounding boxes (x,y,w,h,conf), full text, by-zone text (top/middle/bottom), button annotations
- `css`: CSS custom properties (--bg, --text, --primary, --border, --radius, --surface)

## Agent-Specific Setup

### Opencode
Installed automatically via `npm install -g image-to-code`. If manual:
```bash
# Copy to opencode skills
mkdir -p ~/.opencode/skills/image-to-code/
cp node_modules/image-to-code/SKILL.md ~/.opencode/skills/image-to-code/
```

### Claude Code CLI
Add to `~/.claude/CLAUDE.md` or project `CLAUDE.md`:
```markdown
When you need to analyze images, use:
- `npx image-to-code <file>` — full analysis
- `npx image-to-code <file> --json` — machine-readable only
- `npx image-to-code --clipboard` — from clipboard
```

### Cursor
Create `.cursorrules`:
```markdown
Image analysis tool: npx image-to-code <file> [--json|--full|--clipboard]
```

### Windsurf
Create `.windsurfrules`:
```markdown
Image analysis tool: npx image-to-code <file> [--json|--full|--clipboard]
```

## What This Tool Can Extract

| Feature | Description |
|---------|-------------|
| Colors | dominant palette, bg/text/button/border, WCAG contrast, harmony |
| Layout | sections, columns, hero-padding, bottom segments |
| OCR Text | Thai+English, bounding boxes, multi-PSM, footer/branding scans |
| UI Buttons | identified from bounding box heuristics |
| CSS | custom properties, media queries, surface colors |
| Photo/UI | classifies image as photo background vs flat UI |

## Prerequisites (Auto-Handled)

- Python 3.10+ (auto-detected)
- Pillow + pytesseract (auto-installed via pip on first run)
- Tesseract OCR (must be installed on system)
- Thai language data (auto-downloaded from GitHub on first OCR use)

## Need to Install Tesseract?

```bash
# macOS
brew install tesseract tesseract-lang

# Linux (Ubuntu/Debian)
sudo apt install tesseract-ocr tesseract-ocr-tha

# Windows
winget install -e --id UB-Mannheim.TesseractOCR
```

## Thai Language Support

- Thai text (U+0E00–U+0E7F) auto-merged with `merge_thai_text()`
- Thai traineddata auto-downloads on first OCR use
- Default language: `tha+eng`
