# Batch QR runner

Runs every image in a folder through the app's QR detection N times on each connected iPhone, in
parallel, and writes one CSV row per run.

```
scripts/run_batch.sh [-d] [-n COUNT] [-r REPEATS] [-s SOURCE_DIR] [-o OUT_DIR] [UDID ...]
```

| Flag | Meaning | Default |
|---|---|---|
| `-d` | Dry run: pick images, print the plan, touch nothing | off |
| `-n` | Limit to the first COUNT images (0 = all) | 0 |
| `-r` | Repeats per image per phone | 10 |
| `-s` | Folder containing `<run>/<concentration>/<image>.png` | AAAE validation images |
| `-o` | Output folder | `batch-results/<timestamp>` (git-ignored) |
| `UDID ...` | Phones to use | every phone connected by USB |

## What a run does
1. **Select images:** `*_originals_backup` folders are skipped, and only the first image per distinct QR
   code is kept (QR decoded on the Mac; cached). `selection.csv` lists every image and why it was kept or skipped.
2. **Build once**, then per phone, in parallel: uninstall the app (clean container), install, copy the images,
   run the `test3_RunFolder` UI test (it taps **Run Folder** once), pull the results.
3. **Retry/resume:** if a phone drops or the app dies, the run is resumed (up to 3 attempts); finished runs are never repeated.
4. **Merge** into `report.csv`, `summary.csv`, `cross_device.csv`.

Each phone needs: USB, unlocked, Developer Mode on, Settings > Developer > **Enable UI Automation** on.

## report.csv - one row per run
`serial, run_id, batch_id, strip_code, image_id, image_path, device_name, device_model, os_version,
vision_revision, device_udid, repeat, found, tl_x..bl_y (8 corner columns, 7 decimals), confidence,
vision_requested_revision, vision_revision_verified, vision_crosscheck, vision_supported_revisions,
pixel_w, pixel_h, detect_ms, captured_at, capture_id, failure_reason`

- **run_id** = `<strip_code>_<image_id>_<device>_run<NN>`, e.g. `SJJ9PUA6_c0-rep1_iPhone17ProMax_run03`.
  `rep1` is the replicate image in the source folder; `run03` is the 3rd repeat of that image on that phone.
- **vision_revision** is the revision Vision stamped on the result itself. `vision_revision_verified` is `yes` only when
  it equals the requested revision **and** re-running the image pinned to that revision reproduced the same payload and
  corners bit for bit (`vision_crosscheck` = `pass`).
- Runs that found no QR still get a row (`found` = `no`, reason in `failure_reason`).

## cross_device.csv - one row per image
Per image across every phone and repeat: distinct strip codes and corner sets, max corner deviation within a phone
and across phones (px), `consistent` (bit-exact) and `consistent_within_0.001px`, and mean detect time per phone model.
Different chips can differ in the 7th decimal; the tolerance column separates that from real disagreement.

## Other test modes (not used by the script)
`BatchUITests` also has a picker-driven path (`test1_SeedPhotos`, `test2_Rep01`..`10`) that drives Scan > Pick Photo.
It is slower (about 4.5 s per image) and taps picker cells by screen position.
