#!/usr/bin/env python3
"""Merge per-device QRCaptures sidecars and UI timings into report.csv and summary.csv."""
import csv, glob, json, os, re, statistics, sys

out, stage = sys.argv[1], sys.argv[2]
inputs = sorted(os.listdir(stage))

def ui_timings(devdir):
    """(repeat, index) -> (ui_cycle_ms, outcome), from the per-repeat xcresult attachments."""
    result, total = {}, 0
    for path in glob.glob(os.path.join(devdir, "attachments", "**", "*"), recursive=True):
        if not os.path.isfile(path) or path.endswith(".json"): continue
        try:
            lines = open(path).read().splitlines()
        except Exception:
            continue
        if not lines or not lines[0].startswith("repeat,image_index"): continue
        for row in csv.DictReader(lines):
            if row["repeat"] == "total":
                total += int(row["ui_cycle_ms"])
            else:
                result[(int(row["repeat"]), int(row["image_index"]))] = (int(row["ui_cycle_ms"]), row["outcome"])
    if total: result["total"] = total
    return result

# Captures older than this run's start are leftovers from an earlier run, never merged.
from datetime import datetime
started_file = os.path.join(out, "started.txt")
run_start = float(open(started_file).read()) if os.path.exists(started_file) else 0.0
def is_current(record):
    return datetime.fromisoformat(record["date"].replace("Z", "+00:00")).timestamp() >= run_start

COLS = ["serial", "run_id", "batch_id", "strip_code", "image_id", "image_path", "device_name", "device_model",
        "os_version", "vision_revision", "device_udid", "repeat", "found", "tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y",
        "confidence", "vision_requested_revision", "vision_revision_verified",
        "vision_crosscheck", "vision_supported_revisions", "pixel_w", "pixel_h", "detect_ms", "ui_cycle_ms", "captured_at",
        "capture_id", "outcome"]
CORNER_COLS = ["tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y"]
batch_id = os.path.basename(os.path.normpath(out))
stem_index = {os.path.splitext(name)[0]: n for n, name in enumerate(inputs)}
rows, summary = [], []

def image_parts(input_file):
    """000__SQPT-AAAE_QC_08_10_26__12pt5__12pt5_Rep_1.png -> ('c12pt5-rep1', 'SQPT-AAAE_QC_08_10_26/12pt5/12pt5_Rep_1.png')."""
    parts = input_file.split("__")
    if len(parts) != 4:
        return os.path.splitext(input_file)[0], input_file
    _, run, conc, fname = parts
    rep = re.search(r"_Rep_(\d+)", fname)
    return f"c{conc}-rep{rep.group(1) if rep else '?'}", f"{run}/{conc}/{fname}"

def slug(name):
    return re.sub(r"[^A-Za-z0-9]", "", name)

def fmt(v):
    return f"{float(v):.7f}"

for devdir in sorted(d for d in glob.glob(os.path.join(out, "*")) if os.path.isdir(os.path.join(d, "QRCaptures")) or os.path.exists(os.path.join(d, "run.log"))):
    udid = os.path.basename(devdir)
    timings = ui_timings(devdir)
    records, failures = [], []
    jsonl = os.path.join(devdir, "BatchOutput", "results.jsonl")
    if os.path.exists(jsonl):
        for line in open(jsonl):
            line = line.strip()
            if not line: continue
            item = json.loads(line)
            if not is_current(item): continue
            (failures if item.get("failed") else records).append(item)
    for p in glob.glob(os.path.join(devdir, "QRCaptures", "**", "*.json"), recursive=True):
        record = json.load(open(p))
        if is_current(record): records.append(record)
    records.sort(key=lambda r: r["date"])
    count = len(inputs)
    model = records[0].get("deviceCode", "") if records else ""
    dname = next((r.get("deviceName") for r in records if r.get("deviceName")), model)
    osv = next((r.get("osVersion") for r in records if r.get("osVersion")), "")
    for r in records:
        rep = r.get("batchRepeat") or 0
        idx = stem_index.get(r.get("sourceName"), 0)
        ui = timings.get((rep, idx), ("", ""))
        req, obs, cc = r.get("visionRequestedRevision"), r.get("visionRevision"), r.get("visionRevisionCrosscheck")
        c = r["corners"]
        rows.append({
            "device_udid": udid, "device_name": r.get("deviceName") or dname, "device_model": r.get("deviceCode", ""),
            "os_version": r.get("osVersion") or osv, "repeat": rep, "image_index": idx,
            "input_file": inputs[idx] if idx < len(inputs) else "", "found": "yes",
            "strip_code": r.get("payload"), "confidence": r.get("confidence"),
            "vision_requested_revision": req,
            "vision_revision_verified": "yes" if (req is not None and req == obs and cc is True) else "NO",
            "vision_crosscheck": {True: "pass", False: "FAIL", None: "not run"}[cc],
            "vision_supported_revisions": "/".join(str(v) for v in r.get("visionSupportedRevisions") or []),
            "tl_x": c["topLeft"]["x"], "tl_y": c["topLeft"]["y"], "tr_x": c["topRight"]["x"], "tr_y": c["topRight"]["y"],
            "br_x": c["bottomRight"]["x"], "br_y": c["bottomRight"]["y"], "bl_x": c["bottomLeft"]["x"], "bl_y": c["bottomLeft"]["y"],
            "pixel_w": r["imagePixelWidth"], "pixel_h": r["imagePixelHeight"],
            "detect_ms": r.get("detectMilliseconds"), "ui_cycle_ms": ui[0], "vision_revision": r.get("visionRevision"),
            "captured_at": r["date"], "capture_id": r["id"], "outcome": ui[1],
        })
    for f in failures:
        idx = stem_index.get(f["sourceName"], 0)
        rows.append({"device_udid": udid, "device_name": f.get("deviceName") or dname, "device_model": f.get("deviceCode", model),
                     "os_version": f.get("osVersion") or osv, "repeat": f["batchRepeat"], "image_index": idx,
                     "input_file": inputs[idx] if idx < len(inputs) else "", "found": "no", "captured_at": f["date"],
                     "outcome": f["error"]})
    # UI cycles that produced no record (no QR found / error) still get a row, so the repeat count stays complete.
    seen = {(r["repeat"], r["image_index"]) for r in rows if r["device_udid"] == udid}
    for key, val in timings.items():
        if key == "total" or key in seen: continue
        rep, idx = key
        rows.append({"device_udid": udid, "device_name": dname, "device_model": model, "os_version": osv,
                     "repeat": rep, "image_index": idx, "input_file": inputs[idx] if idx < len(inputs) else "",
                     "found": "no", "ui_cycle_ms": val[0], "outcome": val[1]})
    det = [r["detect_ms"] for r in rows if r["device_udid"] == udid and r.get("detect_ms") not in (None, "")]
    cyc = [r["ui_cycle_ms"] for r in rows if r["device_udid"] == udid and r.get("ui_cycle_ms") not in (None, "")]
    wall = ""
    if os.path.exists(os.path.join(devdir, "wall.txt")):
        wall = open(os.path.join(devdir, "wall.txt")).readline().strip().split("=")[1]
    p95 = lambda v: sorted(v)[max(0, int(round(0.95 * len(v))) - 1)] if v else ""
    summary.append({"device_udid": udid, "device_name": dname, "device_model": model, "os_version": osv,
                    "runs": len(records),
                    "revision_verified": sum(1 for r in rows if r["device_udid"] == udid and r.get("vision_revision_verified") == "yes"),
                    "xcodebuild_wall_s": wall, "ui_total_ms": timings.get("total", ""),
                    "ui_cycle_mean_ms": round(statistics.mean(cyc), 1) if cyc else "", "ui_cycle_p95_ms": p95(cyc),
                    "detect_mean_ms": round(statistics.mean(det), 2) if det else "", "detect_p95_ms": round(p95(det), 2) if det else ""})

# Fill in identifiers. A failed run has no payload of its own, so it borrows the strip code
# another run of the same image decoded.
strip_for_image = {}
for r in rows:
    if r.get("strip_code"):
        strip_for_image.setdefault(r["image_index"], r["strip_code"])
for r in rows:
    r["image_id"], r["image_path"] = image_parts(r["input_file"])
    r["strip_code"] = r.get("strip_code") or strip_for_image.get(r["image_index"], "NOSTRIP")
    r["batch_id"] = batch_id
    r["run_id"] = f"{r['strip_code']}_{r['image_id']}_{slug(r['device_name'])}_run{r['repeat']:02d}"

rows.sort(key=lambda r: (r["image_index"], r["device_udid"], r["repeat"]))
for n, r in enumerate(rows, 1):
    r["serial"] = n

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
        "image_index": idx, "image_id": group[0]["image_id"], "input_file": group[0]["input_file"],
        "devices": len(per_dev), "runs_total": len(group), "runs_found": len(hits),
        "strip_codes_distinct": len({r["strip_code"] for r in hits}),
        "corner_sets_distinct": len({corner_vec(r) for r in hits}),
        "max_dev_within_device_px": round(within, 6),
        "max_dev_across_devices_px": round(max_dev([corner_vec(r) for r in hits]), 6),
        "pixel_sizes_distinct": len({(r["pixel_w"], r["pixel_h"]) for r in hits}),
        "vision_revisions": "/".join(sorted({str(r["vision_revision"]) for r in hits})),
    }
    row["consistent"] = "yes" if (row["runs_found"] == row["runs_total"] and row["strip_codes_distinct"] == 1
                                  and row["corner_sets_distinct"] == 1) else "NO"
    for model in models:
        d = [float(r["detect_ms"]) for r in hits if r["device_model"] == model and r["detect_ms"] not in (None, "")]
        row[f"detect_mean_ms_{model}"] = round(statistics.mean(d), 2) if d else ""
    cross.append(row)
CROSS_COLS = ["image_index", "image_id", "input_file", "devices", "runs_total", "runs_found", "consistent", "strip_codes_distinct",
              "corner_sets_distinct", "max_dev_within_device_px", "max_dev_across_devices_px",
              "pixel_sizes_distinct", "vision_revisions"] + [f"detect_mean_ms_{m}" for m in models]
with open(os.path.join(out, "cross_device.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=CROSS_COLS, extrasaction="ignore"); w.writeheader(); w.writerows(cross)
bad = [c["image_index"] for c in cross if c["consistent"] != "yes"]
print(f"cross-device: {len(cross)} images, {len(cross) - len(bad)} consistent" + (f", INCONSISTENT: {bad}" if bad else ""))
def printable(r):
    """Corners at 7 decimals in the CSV; the comparisons above used the raw values."""
    return {**r, **{k: fmt(r[k]) for k in CORNER_COLS if r.get(k) not in (None, "")}}

for name, cols, data in (("report.csv", COLS, [printable(r) for r in rows]),
                         ("summary.csv", list(summary[0].keys()) if summary else [], summary)):
    with open(os.path.join(out, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore"); w.writeheader(); w.writerows(data)
print(f"{len(rows)} rows from {len(summary)} devices")
