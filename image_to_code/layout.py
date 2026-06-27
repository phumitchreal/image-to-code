"""Layout detection: horizontal sections, vertical columns, component labeling."""

from PIL import Image


def _dominant_color(img, x1, y1, x2, y2, step=8):
    counts = {}
    for y in range(y1, y2, step):
        for x in range(x1, x2, step):
            px = img.getpixel((x, y))
            rq = round(px[0] / 20) * 20
            gq = round(px[1] / 20) * 20
            bq = round(px[2] / 20) * 20
            rq = max(0, min(255, rq))
            gq = max(0, min(255, gq))
            bq = max(0, min(255, bq))
            hex_c = f"#{rq:02X}{gq:02X}{bq:02X}"
            counts[hex_c] = counts.get(hex_c, 0) + 1
    if not counts:
        return "#000000"
    return max(counts, key=counts.get)


def detect_layout(image_path):
    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    coarse_colors = set()
    lum_vals = []
    for y in range(0, h, max(1, h // 30)):
        for x in range(0, w, max(1, w // 30)):
            px = img.getpixel((x, y))
            hex_c = f"#{px[0] & 0xF0:02X}{px[1] & 0xF0:02X}{px[2] & 0xF0:02X}"
            coarse_colors.add(hex_c)
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
        len(coarse_colors) > 50
        or (len(coarse_colors) >= 15 and iqr < 80)
        or (lum_range > 150 and edge_ratio < 0.3)
    )

    scan_resolution = max(8, h // 60) if is_photo else 4

    sections = []
    prev_color = ""
    section_start = 0

    for y in range(0, h, scan_resolution):
        end_y = min(h, y + scan_resolution)
        row_color = _dominant_color(img, 0, y, w, end_y, 8)
        if row_color != prev_color and prev_color != "":
            sections.append({"y": section_start, "h": y - section_start, "color": prev_color})
            section_start = y
        prev_color = row_color

    if h - section_start > 2:
        sections.append({"y": section_start, "h": h - section_start, "color": prev_color})

    columns = []
    if not is_photo:
        min_col_w = int(w * 0.08)
        x_step = max(1, w // 80)
        prev_col_color = ""
        col_start = 0
        for x in range(0, w, x_step):
            end_x = min(w, x + x_step)
            col_color = _dominant_color(img, x, 0, end_x, h, 10)
            if col_color != prev_col_color and prev_col_color != "":
                col_w = x - col_start
                if col_w >= min_col_w:
                    columns.append({"x": col_start, "w": col_w, "color": prev_col_color})
                col_start = x
            prev_col_color = col_color
        if w - col_start > min_col_w:
            columns.append({"x": col_start, "w": w - col_start, "color": prev_col_color})

    min_height = max(20, int(h * 0.03)) if is_photo else max(8, int(h * 0.02))
    merged_sections = []
    buffer = None
    for s in sections:
        if s["h"] < min_height:
            if buffer is not None:
                buffer["h"] += s["h"]
            else:
                buffer = dict(s)
        else:
            if buffer is not None:
                s["y"] = buffer["y"]
                s["h"] += buffer["h"]
                buffer = None
            merged_sections.append(s)
    if buffer is not None:
        merged_sections.append(buffer)

    components = []
    for s in merged_sections:
        rel_y = round(s["y"] / h * 100)
        rel_h = round(s["h"] / h * 100)

        if rel_y < 3:
            label = "hero-padding" if rel_h > 30 else "top-segment"
        elif rel_y + rel_h > 97:
            label = "bottom-segment"
        elif rel_h > 50:
            label = "large-segment"
        elif rel_h < 5:
            label = "thin-band"
        else:
            label = "mid-segment"

        components.append(
            {
                "type": label,
                "y_pct": rel_y,
                "h_pct": rel_h,
                "y_px": s["y"],
                "h_px": s["h"],
                "color": s["color"],
            }
        )

    img.close()

    layout_type = "mobile" if w <= 430 else ("landscape/desktop" if w > h else "tablet/mobile")

    return {
        "imageWidth": w,
        "imageHeight": h,
        "isPhoto": is_photo,
        "layoutType": layout_type,
        "sections": merged_sections,
        "columns": columns,
        "components": components,
    }
