#!/usr/bin/env python3
"""Extract bitmap and vector figures from a PDF with PyMuPDF.

Called by bma.io.extractPdfFigures when PyMuPDF is available. The output JSON
is compatible with bma.literatureFigures.v1 and adds renderer/class metadata.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

try:
    import pymupdf
except Exception:  # pragma: no cover - older PyMuPDF exposes fitz
    import fitz as pymupdf  # type: ignore


def union(a, b, gap=0.0):
    return pymupdf.Rect(min(a.x0, b.x0) - gap, min(a.y0, b.y0) - gap,
                        max(a.x1, b.x1) + gap, max(a.y1, b.y1) + gap)


def merge_clusters(rects, gap=8.0):
    boxes = [pymupdf.Rect(r) for r in rects]
    changed = True
    while changed:
        changed = False
        out = []
        while boxes:
            cur = boxes.pop(0)
            merged = False
            rest = []
            for other in boxes:
                expanded = pymupdf.Rect(cur.x0 - gap, cur.y0 - gap,
                                        cur.x1 + gap, cur.y1 + gap)
                if expanded.intersects(other):
                    cur = union(cur, other)
                    merged = True
                else:
                    rest.append(other)
            boxes = rest
            out.append(cur)
            changed = changed or merged
        boxes = out
    return boxes


def page_caption(page):
    try:
        blocks = page.get_text("blocks")
    except Exception:
        return ""
    for block in blocks:
        text = " ".join(str(block[4]).split())
        low = text.lower()
        if low.startswith("fig") or low.startswith("figure"):
            return text[:300]
    return ""


def add_entry(out, seen, name, path, page_no, rect, kind, caption, source, width, height):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest in seen:
        try:
            path.unlink()
        except OSError:
            pass
        return False
    seen.add(digest)
    entry = {
        "index": len(out["figures"]) + 1,
        "file": name,
        "kind": kind,
        "rasterized": True,
        "width": int(width),
        "height": int(height),
        "page": int(page_no),
        "caption": caption,
        "bytes": path.stat().st_size,
        "filter": "PyMuPDF",
        "format": path.suffix.lower().lstrip("."),
        "sha256": digest,
        "source": source,
    }
    if rect is not None:
        entry["bbox"] = [round(float(v), 3) for v in (rect.x0, rect.y0, rect.x1, rect.y1)]
    out["figures"].append(entry)
    return True


def render_pdf(pdf_path, out_dir, dpi=200, max_figures=80, min_cluster_area=8000,
               gap=8.0, render_pages=False):
    pdf_path = Path(pdf_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open(str(pdf_path))
    out = {
        "schema": "bma.literatureFigures.v1",
        "source": str(pdf_path),
        "figures": [],
        "count": 0,
        "figure_class": "",
        "vector_only": False,
        "rasterized": False,
        "reason": "",
        "renderer": "pymupdf",
        "pages": len(doc),
    }
    seen = set()
    bitmap_count = 0
    vector_count = 0
    page_render_count = 0
    had_drawings = False
    try:
        for page_index, page in enumerate(doc):
            if out["count"] >= max_figures:
                break
            page_no = page_index + 1
            page_rect = page.rect
            caption = page_caption(page)
            base = f"fig{page_no:02d}"
            try:
                images = page.get_images(full=True)
            except Exception:
                images = []
            for image_no, img in enumerate(images, start=1):
                if out["count"] >= max_figures:
                    break
                xref = img[0]
                try:
                    info = doc.extract_image(xref)
                except Exception:
                    continue
                ext = str(info.get("ext", "")).lower()
                if ext not in {"png", "jpg", "jpeg"}:
                    continue
                data = info.get("image")
                if not data:
                    continue
                try:
                    rects = page.get_image_rects(xref)
                except Exception:
                    rects = []
                rect = rects[0] if rects else None
                if rect is not None and (rect.width < 20 or rect.height < 20):
                    continue
                if not caption and (info.get("width", 0) < 200 or info.get("height", 0) < 120):
                    continue
                ext_out = "jpg" if ext in {"jpg", "jpeg"} else "png"
                name = f"{base}_img{image_no:02d}.{ext_out}"
                path = out_dir / name
                path.write_bytes(data)
                if add_entry(out, seen, name, path, page_no, rect, "bitmap", caption,
                             "embedded_image", info.get("width", 0), info.get("height", 0)):
                    bitmap_count += 1
            try:
                drawings = page.get_drawings()
            except Exception:
                drawings = []
            if drawings:
                had_drawings = True
            rects = []
            for drawing in drawings:
                r = drawing.get("rect")
                if r is None:
                    continue
                rr = pymupdf.Rect(r)
                rr = rr & page_rect
                if rr.is_empty:
                    continue
                if rr.width < 2 or rr.height < 2:
                    continue
                if rr.width * rr.height >= page_rect.width * page_rect.height * 0.95:
                    continue
                rects.append(rr)
            clusters = merge_clusters(rects, gap=gap)
            clusters = [c for c in clusters
                        if c.width >= 80 and c.height >= 60
                        and c.width * c.height >= min_cluster_area
                        and c.width * c.height < page_rect.width * page_rect.height * 0.98]
            clusters.sort(key=lambda r: (r.y0, r.x0))
            for cluster_no, clip in enumerate(clusters, start=1):
                if out["count"] >= max_figures:
                    break
                pad = 10.0
                clip = pymupdf.Rect(max(page_rect.x0, clip.x0 - pad),
                                    max(page_rect.y0, clip.y0 - pad),
                                    min(page_rect.x1, clip.x1 + pad),
                                    min(page_rect.y1, clip.y1 + pad))
                if clip.is_empty or clip.width * clip.height < min_cluster_area:
                    continue
                pix = page.get_pixmap(matrix=pymupdf.Matrix(dpi / 72.0, dpi / 72.0),
                                      clip=clip, alpha=False)
                name = f"{base}_vec{cluster_no:02d}.png"
                path = out_dir / name
                pix.save(str(path))
                if add_entry(out, seen, name, path, page_no, clip, "vector_render",
                             caption, "vector_drawing", pix.width, pix.height):
                    vector_count += 1
            if render_pages and not clusters and out["count"] < max_figures:
                low = caption.lower()
                looks_like_figure = ("fig" in low or "figure" in low) and len(drawings) >= 8
                if looks_like_figure:
                    pix = page.get_pixmap(matrix=pymupdf.Matrix(dpi / 72.0, dpi / 72.0),
                                          alpha=False)
                    name = f"{base}_page.png"
                    path = out_dir / name
                    pix.save(str(path))
                    if add_entry(out, seen, name, path, page_no, page_rect,
                                 "page_render", caption, "full_page", pix.width, pix.height):
                        page_render_count += 1
    finally:
        doc.close()
    out["count"] = len(out["figures"])
    out["bitmap_count"] = bitmap_count
    out["vector_render_count"] = vector_count
    out["page_render_count"] = page_render_count
    out["vector_only"] = bitmap_count == 0 and (vector_count + page_render_count) > 0
    out["rasterized"] = out["count"] > 0
    out["reason"] = "pymupdf_render" if out["count"] > 0 else "no_figure_region"
    if out["count"] > 0:
        if bitmap_count and (vector_count + page_render_count):
            out["figure_class"] = "mixed"
        elif vector_count or page_render_count:
            out["figure_class"] = "vector"
        else:
            out["figure_class"] = "bitmap"
    elif had_drawings:
        out["figure_class"] = "vector"
        out["vector_only"] = True
        out["rasterized"] = False
        out["reason"] = "no_figure_region"
    else:
        out["figure_class"] = "unknown"
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--out-json", required=True)
    parser.add_argument("--dpi", type=int, default=200)
    parser.add_argument("--max-figures", type=int, default=80)
    parser.add_argument("--min-cluster-area", type=float, default=8000)
    parser.add_argument("--gap", type=float, default=8.0)
    parser.add_argument("--render-pages", action="store_true")
    args = parser.parse_args()
    out = render_pdf(args.pdf, args.out_dir, dpi=args.dpi,
                     max_figures=args.max_figures,
                     min_cluster_area=args.min_cluster_area,
                     gap=args.gap, render_pages=args.render_pages)
    with open(args.out_json, "w", encoding="utf-8") as handle:
        json.dump(out, handle, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
