"""OCR module: Tesseract-based text extraction with preprocessing, footer/branding scans, Thai merging."""

import os
import re
import tempfile
from PIL import Image, ImageFilter, ImageOps
import pytesseract

from .utils import merge_thai_text


def _histogram_stretch(img):
    """Apply histogram stretch to enhance contrast."""
    gray = img.convert("L")
    pixels = list(gray.getdata())
    min_l = min(pixels)
    max_l = max(pixels)
    rng = max(1, max_l - min_l)
    result = Image.new("L", img.size)
    result.putdata([max(0, min(255, int((p - min_l) / rng * 255))) for p in pixels])
    return result


def _adaptive_threshold(img):
    """Apply threshold to create high-contrast BW."""
    gray = img.convert("L")
    pixels = list(gray.getdata())
    new_pixels = []
    for p in pixels:
        if p < 100:
            np_val = 0
        elif p > 160:
            np_val = 255
        else:
            np_val = max(0, min(255, (p - 80) * 3))
        new_pixels.append(np_val)
    result = Image.new("L", img.size)
    result.putdata(new_pixels)
    return result


def _classify_image(img):
    """Returns (is_photo, lum_vals) for photo vs UI classification."""
    w, h = img.size
    color_sample = set()
    lum_vals = []
    for y in range(0, h, max(1, h // 50)):
        for x in range(0, w, max(1, w // 50)):
            px = img.getpixel((x, y))
            hex_c = f"#{px[0] & 0xF0:02X}{px[1] & 0xF0:02X}{px[2] & 0xF0:02X}"
            color_sample.add(hex_c)
            lum_vals.append(int(0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]))

    edge_count = total_pairs = 0
    for i in range(0, len(lum_vals) - 1, 2):
        if abs(lum_vals[i] - lum_vals[i + 1]) > 40:
            edge_count += 1
        total_pairs += 1
    edge_ratio = edge_count / total_pairs if total_pairs > 0 else 0

    sorted_lums = sorted(lum_vals)
    iqr = 0
    if len(sorted_lums) >= 4:
        q1 = sorted_lums[len(sorted_lums) // 4]
        q3 = sorted_lums[len(sorted_lums) * 3 // 4]
        iqr = q3 - q1
    lum_range = sorted_lums[-1] - sorted_lums[0] if len(sorted_lums) >= 2 else 0

    is_photo = (
        len(color_sample) > 50
        or (len(color_sample) >= 15 and iqr < 80)
        or (lum_range > 150 and edge_ratio < 0.3)
    )
    return is_photo, lum_vals, len(color_sample)


def _tsv_to_boxes(tsv_text, min_confidence, h, w, y_offset=0):
    """Parse Tesseract TSV output into structured box list."""
    boxes = []
    lines = [l.strip() for l in tsv_text.split("\n") if l.strip()]
    if len(lines) < 2:
        return boxes

    header = lines[0].split("\t")
    col_map = {name: idx for idx, name in enumerate(header)}

    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) < 12:
            continue

        text = cols[col_map.get("text", -1)] if "text" in col_map else ""
        conf_str = cols[col_map.get("conf", -1)] if "conf" in col_map else ""
        conf = 0.0
        try:
            conf = float(conf_str)
        except (ValueError, IndexError):
            pass

        if not text.strip() or conf < min_confidence:
            continue

        def _safe_int(idx_key, default=0):
            try:
                return int(cols[col_map[idx_key]])
            except (ValueError, IndexError, KeyError):
                return default

        bw = _safe_int("width")
        bh = _safe_int("height")
        if bw < 8 and bh < 8:
            continue

        bx = _safe_int("left")
        by = _safe_int("top") + y_offset

        boxes.append(
            {
                "text": text.strip(),
                "conf": round(conf, 1),
                "x": bx,
                "y": by,
                "w": bw,
                "h": bh,
                "zone": "top" if by < h / 3 else ("middle" if by < h * 2 / 3 else "bottom"),
            }
        )
    return boxes


def _dedup_boxes(boxes, new_boxes, img_h):
    """Deduplicate boxes: skip dups/substrings, extend longer versions."""
    for nb in new_boxes:
        word = nb["text"]
        x, y = nb["x"], nb["y"]

        dup = any(
            b["text"] == word and abs(b["x"] - x) < 40 and abs(b["y"] - y) < 40 for b in boxes
        )
        subdup = False
        if len(word) >= 3:
            subdup = any(
                word in b["text"] and abs(b["y"] - y) < 30 for b in boxes
            )
        extend = [
            b
            for b in boxes
            if word.startswith(b["text"])
            and abs(b["y"] - y) < 30
            and len(word) > len(b["text"])
        ]

        if extend:
            for b in boxes:
                if b in extend:
                    b["text"] = word

        if not dup and not subdup and not extend:
            nb["zone"] = "top" if y < img_h / 3 else ("middle" if y < img_h * 2 / 3 else "bottom")
            boxes.append(nb)
    return boxes


def extract_text(image_path, language="tha+eng", min_confidence=70):
    """Extract text from image using Tesseract OCR with preprocessing."""
    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    is_photo, _, _ = _classify_image(img)

    orig_path = image_path
    preprocessed_paths = [orig_path]

    if is_photo:
        pp1 = _histogram_stretch(img)
        pp1_path = os.path.join(tempfile.gettempdir(), f"img2code_pp1_{os.urandom(4).hex()}.png")
        pp1.save(pp1_path)
        pp1.close()
        preprocessed_paths.append(pp1_path)

        pp2_img = _adaptive_threshold(img)
        pp2_path = os.path.join(tempfile.gettempdir(), f"img2code_pp2_{os.urandom(4).hex()}.png")
        pp2_img.save(pp2_path)
        pp2_img.close()
        preprocessed_paths.append(pp2_path)

    all_boxes = []
    psm_modes = [3, 6, 4, 11] if is_photo else [3, 11, 6, 4]

    for pp_path in preprocessed_paths:
        for psm in psm_modes:
            try:
                tsv = pytesseract.image_to_data(
                    Image.open(pp_path),
                    lang=language,
                    config=f"--psm {psm}",
                    output_type=pytesseract.Output.DICT,
                )
            except Exception:
                continue

            num_items = len(tsv.get("text", []))
            for i in range(num_items):
                text = tsv["text"][i] if i < len(tsv["text"]) else ""
                try:
                    conf = float(tsv["conf"][i]) if i < len(tsv["conf"]) else -1
                except (ValueError, TypeError):
                    conf = -1

                if not text or text.strip() == "" or conf < min_confidence:
                    continue

                bw = int(tsv["width"][i]) if i < len(tsv["width"]) else 0
                bh = int(tsv["height"][i]) if i < len(tsv["height"]) else 0
                if bw < 8 and bh < 8:
                    continue

                bx = int(tsv["left"][i]) if i < len(tsv["left"]) else 0
                by = int(tsv["top"][i]) if i < len(tsv["top"]) else 0
                word = text.strip()

                nb = {"text": word, "conf": round(conf, 1), "x": bx, "y": by, "w": bw, "h": bh}
                all_boxes = _dedup_boxes(all_boxes, [nb], h)

    # Footer scan: crop bottom 40px for copyright
    if h > 40:
        footer_crop = img.crop((0, h - 40, w, h))
        footer_stretch = _histogram_stretch(footer_crop)
        footer_paths = [footer_crop, footer_stretch]

        for fc in footer_paths:
            for psm_f in (11, 6):
                try:
                    tsv = pytesseract.image_to_data(
                        fc,
                        lang=language,
                        config=f"--psm {psm_f}",
                        output_type=pytesseract.Output.DICT,
                    )
                except Exception:
                    continue

                num_items = len(tsv.get("text", []))
                for i in range(num_items):
                    text = tsv["text"][i] if i < len(tsv["text"]) else ""
                    try:
                        conf = float(tsv["conf"][i]) if i < len(tsv["conf"]) else -1
                    except (ValueError, TypeError):
                        conf = -1

                    if not text or text.strip() == "" or conf < min_confidence:
                        continue

                    fw = int(tsv["width"][i]) if i < len(tsv["width"]) else 0
                    fh = int(tsv["height"][i]) if i < len(tsv["height"]) else 0
                    if fw < 8 and fh < 8 or fh > 50:
                        continue
                    fx = int(tsv["left"][i]) if i < len(tsv["left"]) else 0
                    if fx > w * 0.92:
                        continue
                    fy = int(tsv["top"][i]) if i < len(tsv["top"]) else 0
                    fy += h - 40

                    nb = {"text": text.strip(), "conf": round(conf, 1), "x": fx, "y": fy, "w": fw, "h": fh, "src": "footer", "psm": psm_f}
                    all_boxes = _dedup_boxes(all_boxes, [nb], h)

    # Branding scan: crop bottom 70px for "MADE BY" text
    if h > 70:
        mb_crop = img.crop((0, h - 70, w, h))
        for psm_mb in (8, 7, 13):
            try:
                tsv = pytesseract.image_to_data(
                    mb_crop,
                    lang=language,
                    config=f"--psm {psm_mb}",
                    output_type=pytesseract.Output.DICT,
                )
            except Exception:
                continue

            num_items = len(tsv.get("text", []))
            for i in range(num_items):
                text = tsv["text"][i] if i < len(tsv["text"]) else ""
                try:
                    conf = float(tsv["conf"][i]) if i < len(tsv["conf"]) else -1
                except (ValueError, TypeError):
                    conf = -1

                if not text or text.strip() == "" or conf < min_confidence:
                    continue

                mw = int(tsv["width"][i]) if i < len(tsv["width"]) else 0
                mh = int(tsv["height"][i]) if i < len(tsv["height"]) else 0
                if mw < 8 and mh < 8 or mh > 50:
                    continue
                mx = int(tsv["left"][i]) if i < len(tsv["left"]) else 0
                if mx > w * 0.92:
                    continue
                my = int(tsv["top"][i]) if i < len(tsv["top"]) else 0
                my += h - 70

                nb = {"text": text.strip(), "conf": round(conf, 1), "x": mx, "y": my, "w": mw, "h": mh, "src": "branding", "psm": psm_mb}
                all_boxes = _dedup_boxes(all_boxes, [nb], h)

    # Retry with preprocessing if word count is low
    if len(all_boxes) < 5:
        stretch_full = _histogram_stretch(img)
        stretch_path = os.path.join(tempfile.gettempdir(), f"img2code_retry_{os.urandom(4).hex()}.png")
        stretch_full.save(stretch_path)
        stretch_full.close()

        for psm_r in (3, 6, 11):
            try:
                tsv = pytesseract.image_to_data(
                    Image.open(stretch_path),
                    lang=language,
                    config=f"--psm {psm_r}",
                    output_type=pytesseract.Output.DICT,
                )
            except Exception:
                continue

            num_items = len(tsv.get("text", []))
            for i in range(num_items):
                text = tsv["text"][i] if i < len(tsv["text"]) else ""
                try:
                    conf = float(tsv["conf"][i]) if i < len(tsv["conf"]) else -1
                except (ValueError, TypeError):
                    conf = -1

                if not text or text.strip() == "" or conf < min_confidence:
                    continue

                rx = int(tsv["left"][i]) if i < len(tsv["left"]) else 0
                ry = int(tsv["top"][i]) if i < len(tsv["top"]) else 0
                rw = int(tsv["width"][i]) if i < len(tsv["width"]) else 0
                rh = int(tsv["height"][i]) if i < len(tsv["height"]) else 0
                nb = {"text": text.strip(), "conf": round(conf, 1), "x": rx, "y": ry, "w": rw, "h": rh}
                all_boxes = _dedup_boxes(all_boxes, [nb], h)

        try:
            os.remove(stretch_path)
        except OSError:
            pass

    # Clean up preprocessed temp files
    for pp in preprocessed_paths[1:]:
        try:
            os.remove(pp)
        except OSError:
            pass

    # Sort boxes by zone, then y, then x
    zone_order = {"top": 1, "middle": 2, "bottom": 3}
    all_boxes.sort(key=lambda b: (zone_order.get(b.get("zone", "middle"), 2), b["y"], b["x"]))

    # Plain-text pass for full text
    raw_text = ""
    raw_candidates = {}
    try:
        raw_candidates["orig"] = pytesseract.image_to_string(img, lang=language, config="--psm 6").strip()
    except Exception:
        pass

    if is_photo or "tha" in language:
        pp_raw = _histogram_stretch(img)
        pp_raw_path = os.path.join(tempfile.gettempdir(), f"img2code_raw_{os.urandom(4).hex()}.png")
        pp_raw.save(pp_raw_path)
        pp_raw.close()
        try:
            raw_candidates["pp"] = pytesseract.image_to_string(
                Image.open(pp_raw_path), lang=language, config="--psm 6"
            ).strip()
        except Exception:
            pass
        try:
            os.remove(pp_raw_path)
        except OSError:
            pass

    if raw_candidates:
        raw_text = max(raw_candidates.values(), key=len)

    raw_text_output = merge_thai_text(raw_text) if raw_text else ""

    img.close()

    # Build byZone
    def _zone_text(zone_name):
        return merge_thai_text(
            " ".join(b["text"] for b in all_boxes if b.get("zone") == zone_name)
        )

    by_zone = {
        "top": _zone_text("top"),
        "middle": _zone_text("middle"),
        "bottom": _zone_text("bottom"),
    }

    return {
        "words": len(all_boxes),
        "boxes": all_boxes,
        "rawText": raw_text_output,
        "byZone": by_zone,
    }
