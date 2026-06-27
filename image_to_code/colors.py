"""Color extraction: dominant colors, semantic roles, gradient, harmony."""

import math
from PIL import Image
from .utils import hex_to_rgb, rgb_to_hex, luminance, contrast_ratio, saturation


def extract_colors(image_path, sample_count=2000, quantize_tolerance=15):
    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    coarse_colors = set()
    lum_vals = []
    c_step_x = max(1, w // 40)
    c_step_y = max(1, h // 40)
    for y in range(0, h, c_step_y):
        for x in range(0, w, c_step_x):
            px = img.getpixel((x, y))
            coarse_hex = f"#{px[0] & 0xF0:02X}{px[1] & 0xF0:02X}{px[2] & 0xF0:02X}"
            coarse_colors.add(coarse_hex)
            lum_vals.append(int(0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]))

    distinct_color_count = len(coarse_colors)

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
        distinct_color_count > 50
        or (distinct_color_count >= 15 and iqr < 80)
        or (lum_range > 150 and edge_ratio < 0.3)
    )

    color_counts = {}
    step_x = max(1, int(w / math.sqrt(sample_count * w / h))) if w and h else 1
    step_y = max(1, int(h / math.sqrt(sample_count * h / w))) if w and h else 1
    total_samples = 0
    for y in range(0, h, step_y):
        for x in range(0, w, step_x):
            px = img.getpixel((x, y))
            rq = round(px[0] / quantize_tolerance) * quantize_tolerance
            gq = round(px[1] / quantize_tolerance) * quantize_tolerance
            bq = round(px[2] / quantize_tolerance) * quantize_tolerance
            rq = max(0, min(255, rq))
            gq = max(0, min(255, gq))
            bq = max(0, min(255, bq))
            hex_c = f"#{rq:02X}{gq:02X}{bq:02X}"
            color_counts[hex_c] = color_counts.get(hex_c, 0) + 1
            total_samples += 1

    sorted_palette = sorted(color_counts.items(), key=lambda x: x[1], reverse=True)
    total = max(1, total_samples)
    palette = []
    color_meta = []
    for hex_c, cnt in sorted_palette:
        pct = round(cnt / total * 100, 1)
        palette.append({"hex": hex_c, "pct": pct, "count": cnt})
        r, g, b = hex_to_rgb(hex_c)
        lum = luminance(r, g, b)
        sat = saturation(r, g, b)
        color_meta.append(
            {"hex": hex_c, "pct": pct, "r": r, "g": g, "b": b, "lum": lum, "sat": round(sat, 1)}
        )

    bg_color = palette[0]["hex"] if palette else "#FFFFFF"
    bg_meta = color_meta[0] if color_meta else None
    bg_lum = bg_meta["lum"] if bg_meta else 255

    surfaces = []
    text_primary = None
    text_secondary = None
    button_color = None
    border_color = None
    border_candidates = []

    if not is_photo:
        text_candidates = []
        button_candidates = []

        for cm in color_meta:
            is_bg = cm["hex"] == bg_color
            cr = contrast_ratio(bg_lum, cm["lum"])
            lum_diff = abs(cm["lum"] - bg_lum)

            if not is_bg and cm["pct"] > 1 and lum_diff < 40:
                surfaces.append(cm)
            if not is_bg and cr > 1.3 and cm["pct"] < 2 and cm["pct"] > 0.05 and lum_diff > 2:
                border_candidates.append({"hex": cm["hex"], "contrast": cr, "lum_diff": lum_diff})
            if not is_bg and cm["sat"] > 20 and cm["lum"] > 30 and cm["pct"] < 5 and cm["pct"] > 0.1:
                button_candidates.append({"hex": cm["hex"], "sat": cm["sat"], "contrast": cr})
            if not is_bg and cr > 3 and cm["pct"] < 3:
                text_candidates.append({"hex": cm["hex"], "contrast": cr, "lum": cm["lum"]})

        surfaces.sort(key=lambda x: x["pct"], reverse=True)

        if text_candidates:
            text_candidates.sort(key=lambda x: x["contrast"], reverse=True)
            text_primary = text_candidates[0]["hex"]
            if len(text_candidates) > 1:
                text_secondary = text_candidates[1]["hex"]
        else:
            text_primary = "#1F2937" if bg_lum > 128 else "#FFFFFF"

        if button_candidates:
            button_candidates.sort(key=lambda x: x["sat"], reverse=True)
            button_color = button_candidates[0]["hex"]
        if border_candidates:
            border_candidates.sort(key=lambda x: x["lum_diff"], reverse=True)
            border_color = border_candidates[0]["hex"]
    else:
        for cm in color_meta:
            is_bg = cm["hex"] == bg_color
            lum_diff = abs(cm["lum"] - bg_lum)
            if not is_bg and cm["pct"] > 0.5 and lum_diff < 50:
                surfaces.append(cm)
        surfaces.sort(key=lambda x: x["pct"], reverse=True)
        text_primary = "#1F2937" if bg_lum > 128 else "#FFFFFF"

        button_candidates = [
            cm
            for cm in color_meta
            if cm["sat"] > 20 and cm["lum"] > 30 and cm["pct"] > 0.1 and cm["pct"] < 5 and cm["hex"] != bg_color
        ]
        if button_candidates:
            button_candidates.sort(key=lambda x: x["sat"], reverse=True)
            button_color = button_candidates[0]["hex"]

        for cm in color_meta:
            is_bg = cm["hex"] == bg_color
            cr = contrast_ratio(bg_lum, cm["lum"])
            lum_diff = abs(cm["lum"] - bg_lum)
            if not is_bg and cr > 1.3 and cm["pct"] < 2 and cm["pct"] > 0.05 and lum_diff > 2:
                border_candidates.append({"hex": cm["hex"], "contrast": cr, "lum_diff": lum_diff})
        if border_candidates:
            border_candidates.sort(key=lambda x: x["lum_diff"], reverse=True)
            border_color = border_candidates[0]["hex"]

    has_gradient = False
    gradient_type = "none"
    gradient_colors = [bg_color]
    grad_threshold = 30 if is_photo else 50

    def _strip_lum(y_start, y_end, step=2):
        tl = cnt = 0
        for yy in range(y_start, min(y_end, h), step):
            for xx in range(0, w, 20):
                px = img.getpixel((xx, yy))
                tl += luminance(px[0], px[1], px[2])
                cnt += 1
        return tl / cnt if cnt else 0

    top_lum = _strip_lum(0, min(50, h))
    mid_lum = _strip_lum(max(0, h // 2 - 25), min(h, h // 2 + 25))
    bot_lum = _strip_lum(max(0, h - 50), h)
    grad_range = max(abs(top_lum - bot_lum), abs(top_lum - mid_lum))

    if grad_range > grad_threshold:
        has_gradient = True
        gradient_type = "vertical-3tone" if (abs(top_lum - mid_lum) > 15 and abs(mid_lum - bot_lum) > 15) else "vertical"

        def _strip_color(y_pos):
            r_sum = g_sum = b_sum = cnt = 0
            for xx in range(w // 3, w * 2 // 3, 10):
                px = img.getpixel((xx, y_pos))
                r_sum += px[0]; g_sum += px[1]; b_sum += px[2]; cnt += 1
            return (r_sum // cnt, g_sum // cnt, b_sum // cnt) if cnt else None

        gradient_colors = []
        for yp in (5, h // 2, h - 5):
            c = _strip_color(yp)
            if c:
                gradient_colors.append(rgb_to_hex(*c))

    img.close()

    tr, tg, tb = hex_to_rgb(text_primary)
    text_lum = luminance(tr, tg, tb)
    br, bg, bb = hex_to_rgb(bg_color)
    bg_lum_calc = luminance(br, bg, bb)
    contrast_ratio_val = round(contrast_ratio(text_lum, bg_lum_calc), 1)

    hues = []
    for cm in color_meta:
        if cm["pct"] <= 0.5:
            continue
        r, g, b = cm["r"], cm["g"], cm["b"]
        mx = max(r, g, b)
        mn = min(r, g, b)
        if mx == mn:
            continue
        d = mx - mn
        if mx == r:
            hv = ((g - b) / d) % 6
        elif mx == g:
            hv = (b - r) / d + 2
        else:
            hv = (r - g) / d + 4
        hd = round(hv * 60)
        if hd < 0:
            hd += 360
        hues.append(hd)

    hue_range = 0
    if len(hues) > 1:
        sh = sorted(hues)
        mg = max(sh[i + 1] - sh[i] for i in range(len(sh) - 1))
        wg = 360 - sh[-1] + sh[0]
        if wg > mg:
            mg = wg
        hue_range = 360 - mg

    if hue_range <= 30:
        harmony = "monochromatic"
    elif hue_range <= 60:
        harmony = "analogous"
    elif 150 <= hue_range <= 210:
        harmony = "complementary"
    else:
        harmony = "neutral"

    surface_colors = [s["hex"] for s in surfaces[:3]] or [bg_color]

    return {
        "imageWidth": w,
        "imageHeight": h,
        "isPhoto": is_photo,
        "distinctColors": distinct_color_count,
        "totalColors": len(palette),
        "samples": total_samples,
        "background": bg_color,
        "surfaces": surface_colors,
        "text": text_primary,
        "textSecondary": text_secondary,
        "button": button_color,
        "border": border_color,
        "contrastRatio": contrast_ratio_val,
        "harmony": harmony,
        "gradient": {"type": gradient_type, "colors": gradient_colors} if has_gradient else None,
        "palette": palette[:20],
    }
