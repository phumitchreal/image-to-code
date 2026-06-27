# image-to-code

> แยกข้อมูลโครงสร้าง (สี, เลย์เอาต์, ข้อความ) จากรูปภาพ **โดยไม่ต้องใช้ AI ภาพ**  
> รองรับทุกแพลตฟอร์ม: macOS · Linux · Windows  
> ใช้ Tesseract OCR + Pillow วิเคราะห์ภาพแบบ programmatic 100%

## ติดตั้ง

### ตัวเลือก 1: NPX (ง่ายที่สุด)

```bash
npx image-to-code รูป.png
```

> ครั้งแรกจะโหลด Python package โดยอัตโนมัติ ต้องการ Python 3.10+

### ตัวเลือก 2: pip

```bash
pip install image-to-code
image-to-code รูป.png
```

### ตัวเลือก 3: จาก source

```bash
git clone https://github.com/phumitchreal/image-to-code.git
cd image-to-code
pip install -r requirements.txt
python -m image_to_code.analyze รูป.png
```

### ติดตั้ง Tesseract OCR

```bash
# macOS
brew install tesseract tesseract-lang

# Linux (Ubuntu/Debian)
sudo apt install tesseract-ocr tesseract-ocr-tha tesseract-ocr-osd

# Linux (Arch)
sudo pacman -S tesseract tesseract-data-tha

# Windows
winget install -e --id UB-Mannheim.TesseractOCR
# หรือโหลดจาก https://github.com/UB-Mannheim/tesseract/wiki
```

> ภาษาไทย (`tha.traineddata`) จะโหลดอัตโนมัติครั้งแรกที่ใช้งาน OCR

## ความสามารถ

| ฟีเจอร์ | รายละเอียด |
|---|---|
| **แยกสี** | สีหลัก, สีพื้นหลัง, สีข้อความ, สีปุ่ม, สีขอบ, WCAG contrast ratio, ประเภทสี harmony, gradient |
| **วิเคราะห์เลย์เอาต์** | หาส่วนแนวนอน, คอลัมน์แนวตั้ง, component labeling (hero-padding, bottom-segment) |
| **OCR ข้อความ** | หลาย PSM mode, histogram stretch + adaptive threshold, สแกน footer/branding เพิ่มเติม, จับกลุ่มตัวอักษรไทย |
| **ปุ่ม UI** | จำแนกปุ่มจากขนาด bounding box |
| **แยกประเภทภาพ** | photo (พื้นหลังออร์แกนิก) vs UI (แบน/ schematic) |
| **CSS Output** | สร้าง CSS custom properties และ media query |
| **Clipboard** | อ่านรูปจากคลิปบอร์ด (`--clipboard`) |

## การใช้งาน

### CLI

```bash
# วิเคราะห์พื้นฐาน
image-to-code screenshot.png

# แสดงเป็น JSON อย่างเดียว
image-to-code screenshot.png --json

# รายงานเต็ม + JSON
image-to-code screenshot.png --full

# อ่านจากคลิปบอร์ด
image-to-code --clipboard

# เปลี่ยนภาษา OCR และความมั่นใจขั้นต่ำ
image-to-code screenshot.png --lang eng --min-confidence 80

# กำหนดจำนวนตัวอย่างสี
image-to-code screenshot.png --sample-count 3000 --quantize-tolerance 20
```

### ใช้เป็น Python Library

```python
from image_to_code.colors import extract_colors
from image_to_code.layout import detect_layout
from image_to_code.ocr import extract_text

colors = extract_colors("image.png")
layout = detect_layout("image.png")
text = extract_text("image.png", language="tha+eng", min_confidence=70)

print(f"พื้นหลัง: {colors['background']}")
print(f"ข้อความ: {colors['text']} (contrast: {colors['contrastRatio']}:1)")
print(f"เลย์เอาต์: {layout['layoutType']}")
print(f"OCR: {text['rawText']}")
```

## ตัวอย่าง Output

```
=======================================================================
   รายงานวิเคราะห์ภาพ
=======================================================================

Image: 1913x995 (landscape/desktop, photo)

--- สี ---
  พื้นหลัง:    #0F0F0F
  พื้นผิว:     #1E1E1E, #000000, #2D2D1E
  ข้อความ:     #FFFFFF  (contrast: 16.9:1)
  ปุ่ม:        #5A69F0
  ขอบ:        #2D1E1E

--- ส่วนประกอบเลย์เอาต์ ---
  hero-padding     y= 0% h=45%  color=#282828
  bottom-segment   y=45% h=53%  color=#141414
  bottom-segment   y=98% h= 2%  color=#000000

--- OCR (35 คำ >=70%) ---
DISCORD COMMUNITY HUB
ติดตามสมาชิกแก๊งแบบเรียลไทม์และดูพาร์ทเนอร์ที่ร่วมงานกับเรา
Gang Partners

--- CSS ---
  --bg: #0F0F0F
  --surface: #1E1E1E
  --text: #FFFFFF
  --primary: #5A69F0
  --border: #2D1E1E
```

## โครงสร้าง JSON Output

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
    "buttons": [ { "text": "Gang", "x": 0, "y": 570, "w": 100, "h": 40 } ],
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

## การทำงานภายใน

### แยกประเภท Photo vs UI
ใช้ 3 heuristic กับ pixel sample:
1. **จำนวนสี distinct** — ภาพถ่ายมี >50 สี (หลัง 4-bit quantization)
2. **Luminance IQR** — ภาพถ่ายมีช่วง interquartile แคบ (<80) + จำนวนสีปานกลาง
3. **Edge ratio** — ภาพถ่ายมี edge ratio ต่ำ (<0.3) บน spatial sample ที่อยู่ติดกัน

### การจัดการภาษาไทย
Tesseract มักแยกตัวอักษรไทยออกเป็น grapheme ย่อยๆ ฟังก์ชัน `merge_thai_text()` จะลบช่องว่างระหว่างอักขระไทย (U+0E00–U+0E7F) เพื่อรวมเป็นคำที่ถูกต้อง

### Adaptive Thresholding
สำหรับภาพพื้นหลังที่เป็นรูปถ่าย จะมีการประมวลผลล่วงหน้า 2 แบบ:
1. Histogram stretch (เพิ่ม contrast เต็มที่)
2. Adaptive threshold (ตัดที่ 100/160 luminance)

OCR จะรันบนทุกเวอร์ชัน (ต้นฉบับ + processed) ด้วยหลาย PSM mode และ deduplicate ผลลัพธ์

## PowerShell Version (Windows)

โฟลเดอร์ `powershell/` มี PowerShell scripts ต้นฉบับ สำหรับ Windows เท่านั้น:

```powershell
.\powershell\analyze-image.ps1 -ImagePath screenshot.png -Full
.\powershell\analyze-image.ps1 -Clipboard
.\powershell\analyze-image.ps1 -ImagePath screenshot.png -Json
```

## License

MIT
