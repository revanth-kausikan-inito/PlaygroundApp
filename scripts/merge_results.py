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
for name, cols, data in (("report.csv", COLS, rows), ("summary.csv", list(summary[0].keys()) if summary else [], summary)):
    with open(os.path.join(out, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore"); w.writeheader(); w.writerows(data)
print(f"{len(rows)} rows from {len(summary)} devices")
