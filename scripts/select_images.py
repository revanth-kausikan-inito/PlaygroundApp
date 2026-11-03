#!/usr/bin/env python3
"""Pick one image per distinct QR code and stage them for a batch run.

    select_images.py SOURCE_DIR STAGE_DIR OUT_DIR [COUNT]

- `*_originals_backup` folders are skipped (their images carry the same QR as the main folders).
- Of images that share a QR payload, only the first (by sorted path) is kept.
- COUNT limits how many kept images are staged; 0 or omitted means all.
Writes OUT_DIR/selection.csv listing every image considered and why it was kept or skipped.
"""
import csv, json, os, shutil, subprocess, sys

src, stage, out = sys.argv[1], sys.argv[2], sys.argv[3]
count = int(sys.argv[4]) if len(sys.argv) > 4 else 0
here = os.path.dirname(os.path.abspath(__file__))

files = []
for root, dirs, names in os.walk(src):
    dirs[:] = sorted(d for d in dirs if not d.endswith("_originals_backup"))
    for n in sorted(names):
        if n.lower().endswith((".png", ".jpg", ".jpeg")):
            files.append(os.path.relpath(os.path.join(root, n), src))
files.sort()

# Decode on the Mac, cached by path + size + mtime so repeat runs don't re-decode everything.
cache_path = os.path.join(here, "..", "batch-results", ".decode-cache.json")
os.makedirs(os.path.dirname(cache_path), exist_ok=True)
cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
def key(rel):
    st = os.stat(os.path.join(src, rel))
    return f"{rel}|{st.st_size}|{int(st.st_mtime)}"
todo = [rel for rel in files if key(rel) not in cache]
if todo:
    binary = os.path.join(out, "qr_decode")
    subprocess.run(["swiftc", "-O", os.path.join(here, "qr_decode.swift"), "-o", binary], check=True,
                   stderr=subprocess.DEVNULL)
    listfile = os.path.join(out, "decode_list.txt")
    open(listfile, "w").write("\n".join(os.path.join(src, rel) for rel in todo))
    result = os.path.join(out, "decode_result.json")
    subprocess.run([binary, listfile, result], check=True, stdout=subprocess.DEVNULL)
    decoded = json.load(open(result))
    for rel in todo:
        cache[key(rel)] = decoded[os.path.join(src, rel)]
    json.dump(cache, open(cache_path, "w"))

first_for, rows, kept = {}, [], []
for rel in files:
    payload = cache[key(rel)]
    if payload != "NONE" and payload in first_for:
        rows.append([rel, "skipped", payload, f"same QR as {first_for[payload]}"])
        continue
    if payload != "NONE":
        first_for[payload] = rel
    kept.append((rel, payload))
    rows.append([rel, "kept", payload, "" if payload != "NONE" else "no QR decoded on Mac; kept"])

staged = kept[:count] if count else kept
os.makedirs(stage, exist_ok=True)
for i, (rel, _) in enumerate(staged):
    run, conc, fname = rel.split(os.sep)
    shutil.copy(os.path.join(src, rel), os.path.join(stage, f"{i:04d}__{run}__{conc}__{fname}"))
staged_set = {rel for rel, _ in staged}
for r in rows:
    if r[1] == "kept" and r[0] not in staged_set:
        r[1], r[3] = "not staged", "beyond COUNT"

with open(os.path.join(out, "selection.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["image_path", "decision", "strip_code", "reason"])
    w.writerows(rows)
print(f"{len(files)} images considered, {len(kept)} distinct QR, {len(staged)} staged")
