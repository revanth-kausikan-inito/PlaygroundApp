#!/usr/bin/env python3
"""Merge per-device QRCaptures sidecars and UI timings into report.csv and summary.csv."""
import csv, glob, json, os, statistics, sys

out, stage = sys.argv[1], sys.argv[2]
inputs = sorted(os.listdir(stage))

def ui_timings(devdir):
    """(repeat, index) -> (ui_cycle_ms, outcome) from the xcresult attachment."""
    result = {}
    for path in glob.glob(os.path.join(devdir, "attachments", "**", "ui_timings*.csv"), recursive=True) + \
               glob.glob(os.path.join(devdir, "attachments", "**", "*"), recursive=True):
        if not os.path.isfile(path) or path.endswith(".json"): continue
        try:
            lines = open(path).read().splitlines()
        except Exception:
            continue
        if not lines or not lines[0].startswith("repeat,image_index"): continue
        for row in csv.DictReader(lines):
            if row["repeat"] == "total":
                result["total"] = int(row["ui_cycle_ms"])
            else:
                result[(int(row["repeat"]), int(row["image_index"]))] = (int(row["ui_cycle_ms"]), row["outcome"])
        break
    return result

COLS = ["device_udid", "device_model", "repeat", "image_index", "input_file", "source_name", "found",
        "payload", "confidence", "tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y",
        "pixel_w", "pixel_h", "detect_ms", "ui_cycle_ms", "vision_revision", "captured_at", "capture_id", "outcome"]
rows, summary = [], []

for devdir in sorted(d for d in glob.glob(os.path.join(out, "*")) if os.path.isdir(os.path.join(d, "QRCaptures")) or os.path.exists(os.path.join(d, "run.log"))):
    udid = os.path.basename(devdir)
    timings = ui_timings(devdir)
    records = []
    for p in glob.glob(os.path.join(devdir, "QRCaptures", "**", "*.json"), recursive=True):
        records.append(json.load(open(p)))
    records.sort(key=lambda r: r["date"])
    count = len(inputs)
    model = records[0].get("deviceCode", "") if records else ""
    for n, r in enumerate(records):
        rep, idx = n // count + 1, n % count
        ui = timings.get((rep, idx), ("", ""))
        c = r["corners"]
        name = r.get("sourceName") or ""
        rows.append({
            "device_udid": udid, "device_model": r.get("deviceCode", ""), "repeat": rep, "image_index": idx,
            "input_file": inputs[idx] if idx < len(inputs) else "", "source_name": name, "found": "yes",
            "payload": r.get("payload"), "confidence": r.get("confidence"),
            "tl_x": c["topLeft"]["x"], "tl_y": c["topLeft"]["y"], "tr_x": c["topRight"]["x"], "tr_y": c["topRight"]["y"],
            "br_x": c["bottomRight"]["x"], "br_y": c["bottomRight"]["y"], "bl_x": c["bottomLeft"]["x"], "bl_y": c["bottomLeft"]["y"],
            "pixel_w": r["imagePixelWidth"], "pixel_h": r["imagePixelHeight"],
            "detect_ms": r.get("detectMilliseconds"), "ui_cycle_ms": ui[0], "vision_revision": r.get("visionRevision"),
            "captured_at": r["date"], "capture_id": r["id"], "outcome": ui[1],
        })
    # UI cycles that produced no record (no QR found / error)
    seen = {(r["repeat"], r["image_index"]) for r in rows if r["device_udid"] == udid}
    for key, val in timings.items():
        if key == "total" or key in seen: continue
        rep, idx = key
        rows.append({"device_udid": udid, "device_model": model, "repeat": rep, "image_index": idx,
                     "input_file": inputs[idx] if idx < len(inputs) else "", "found": "no",
                     "ui_cycle_ms": val[0], "outcome": val[1]})
    det = [r["detect_ms"] for r in rows if r["device_udid"] == udid and r.get("detect_ms") not in (None, "")]
    cyc = [r["ui_cycle_ms"] for r in rows if r["device_udid"] == udid and r.get("ui_cycle_ms") not in (None, "")]
    wall = ""
    if os.path.exists(os.path.join(devdir, "wall.txt")):
        wall = open(os.path.join(devdir, "wall.txt")).read().strip().split("=")[1]
    p95 = lambda v: sorted(v)[max(0, int(round(0.95 * len(v))) - 1)] if v else ""
    summary.append({"device_udid": udid, "device_model": model, "runs": len(records), "xcodebuild_wall_s": wall,
                    "ui_total_ms": timings.get("total", ""),
                    "ui_cycle_mean_ms": round(statistics.mean(cyc), 1) if cyc else "", "ui_cycle_p95_ms": p95(cyc),
                    "detect_mean_ms": round(statistics.mean(det), 2) if det else "", "detect_p95_ms": round(p95(det), 2) if det else ""})

rows.sort(key=lambda r: (r["device_udid"], r["repeat"], r["image_index"]))

# --- cross-device comparison: one row per image, across every device and repeat.
CORNER_KEYS = ["tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y"]
def corner_vec(r): return tuple(float(r[k]) for k in CORNER_KEYS)
def max_dev(vecs):
    """Largest distance between any pair of matching corners over all pairs of results, in px."""
    worst = 0.0
    for i, a in enumerate(vecs):
        for b in vecs[i + 1:]:
            for k in range(0, 8, 2):
                worst = max(worst, ((a[k] - b[k]) ** 2 + (a[k + 1] - b[k + 1]) ** 2) ** 0.5)
    return worst

models = sorted({r["device_model"] for r in rows if r["device_model"]})
cross, by_image = [], {}
for r in rows:
    by_image.setdefault(r["image_index"], []).append(r)
for idx in sorted(by_image):
    group = by_image[idx]
    hits = [r for r in group if r["found"] == "yes"]
    per_dev = {}
    for r in hits:
        per_dev.setdefault(r["device_udid"], []).append(r)
    within = max((max_dev([corner_vec(r) for r in v]) for v in per_dev.values()), default=0.0)
    row = {
        "image_index": idx, "input_file": group[0]["input_file"],
        "devices": len(per_dev), "runs_total": len(group), "runs_found": len(hits),
        "payloads_distinct": len({r["payload"] for r in hits}),
        "corner_sets_distinct": len({corner_vec(r) for r in hits}),
        "max_dev_within_device_px": round(within, 6),
        "max_dev_across_devices_px": round(max_dev([corner_vec(r) for r in hits]), 6),
        "pixel_sizes_distinct": len({(r["pixel_w"], r["pixel_h"]) for r in hits}),
        "vision_revisions": "/".join(sorted({str(r["vision_revision"]) for r in hits})),
    }
    row["consistent"] = "yes" if (row["runs_found"] == row["runs_total"] and row["payloads_distinct"] == 1
                                  and row["corner_sets_distinct"] == 1) else "NO"
    for model in models:
        d = [float(r["detect_ms"]) for r in hits if r["device_model"] == model and r["detect_ms"] not in (None, "")]
        row[f"detect_mean_ms_{model}"] = round(statistics.mean(d), 2) if d else ""
    cross.append(row)
CROSS_COLS = ["image_index", "input_file", "devices", "runs_total", "runs_found", "consistent", "payloads_distinct",
              "corner_sets_distinct", "max_dev_within_device_px", "max_dev_across_devices_px",
              "pixel_sizes_distinct", "vision_revisions"] + [f"detect_mean_ms_{m}" for m in models]
with open(os.path.join(out, "cross_device.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=CROSS_COLS, extrasaction="ignore"); w.writeheader(); w.writerows(cross)
bad = [c["image_index"] for c in cross if c["consistent"] != "yes"]
print(f"cross-device: {len(cross)} images, {len(cross) - len(bad)} consistent" + (f", INCONSISTENT: {bad}" if bad else ""))
for name, cols, data in (("report.csv", COLS, rows), ("summary.csv", list(summary[0].keys()) if summary else [], summary)):
    with open(os.path.join(out, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore"); w.writeheader(); w.writerows(data)
print(f"{len(rows)} rows from {len(summary)} devices")
