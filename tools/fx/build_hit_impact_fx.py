#!/usr/bin/env python3
"""Build canonical reusable default melee/heavy hit impact FX bundle from Owner sample.

Source: /workspaces/Dragonball-Studio-7/image copy 2.png (frame 0 peak burst).
Output:
  - assets/fx/hit_impact/hit_impact-atlas-00.png (896x128, 7x 128x128 crisp pixel-art frames)
  - assets/fx/hit_impact/hit_impact.tres (Godot 4 SpriteFrames, 60Hz, Nearest, non-looping)
  - Optional 3-background QA filmstrip (dark, sand/light, checkerboard) for visual motion_quality audit.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "image copy 2.png"
DEFAULT_OUT_DIR = REPO_ROOT / "assets" / "fx" / "hit_impact"
FRAME_SIZE = 128
WORK_SIZE = 512
NUM_FRAMES = 7


def extract_centered_work_mask(src_path: Path) -> tuple[np.ndarray, float]:
    """Extract binary white-burst mask from dark-checkerboard source and center on its hollow core."""
    im = Image.open(src_path).convert("L")
    arr = np.array(im, dtype=np.float32)

    # Source background checkerboard sits at lum 14..36; foreground burst is pure white (255).
    raw_mask = arr > 105.0

    # Locate true hollow core center via max inscribed circle inside the central region.
    bg_dist = ndimage.distance_transform_edt(~raw_mask)
    h, w = raw_mask.shape
    y0, y1 = int(h * 0.35), int(h * 0.75)
    x0, x1 = int(w * 0.35), int(w * 0.75)
    sub = bg_dist[y0:y1, x0:x1]
    ry, rx = np.unravel_index(np.argmax(sub), sub.shape)
    cx = float(rx + x0)
    cy = float(ry + y0)
    core_radius_src = float(sub[ry, rx])

    # Measure max radial extent from hollow center so Frame 0 leaves clean outward room for expansion.
    ys, xs = np.where(raw_mask)
    max_ext = float(max(
        abs(xs.min() - cx),
        abs(xs.max() - cx),
        abs(ys.min() - cy),
        abs(ys.max() - cy),
    ))
    target_ext = 208.0
    scale = target_ext / max_ext

    grid = np.arange(WORK_SIZE, dtype=np.float32) - (WORK_SIZE * 0.5)
    gx, gy = np.meshgrid(grid, grid)
    sx = cx + gx / scale
    sy = cy + gy / scale
    norm_lum = np.clip((arr - 42.0) / (245.0 - 42.0), 0.0, 1.0)
    sampled = ndimage.map_coordinates(norm_lum, [sy, sx], order=1, mode="constant", cval=0.0)
    work_mask = sampled > 0.36
    core_radius_work = core_radius_src * scale
    return work_mask, core_radius_work


def _angular_wave(theta: np.ndarray) -> np.ndarray:
    """Deterministic multi-harmonic angular modulation so ring fractures occur organically."""
    return (
        0.42 * np.sin(theta * 5.0 + 0.55)
        + 0.33 * np.cos(theta * 8.0 - 1.15)
        + 0.25 * np.sin(theta * 13.0 + 2.10)
    )


def _downsample_crisp_128(work_bool: np.ndarray, min_coverage: float = 0.28) -> np.ndarray:
    """Downsample 512x512 binary burst cleanly to 128x128 binary pixel-art mask."""
    h, _w = work_bool.shape
    factor = h // FRAME_SIZE
    blocks = work_bool.astype(np.float32).reshape(FRAME_SIZE, factor, FRAME_SIZE, factor)
    cov = blocks.mean(axis=(1, 3))
    out = cov >= min_coverage
    # Keep 1px outer border guaranteed empty so sprite never clips at quad edge
    out[0, :] = False
    out[-1, :] = False
    out[:, 0] = False
    out[:, -1] = False
    return out


def build_frames(work_mask: np.ndarray, core_radius: float) -> list[np.ndarray]:
    """Synthesize 7 coherent frames: Frame 0 = exact source; Frames 1..6 = kinetic outward dissipation."""
    half = WORK_SIZE * 0.5
    grid = np.arange(WORK_SIZE, dtype=np.float32) - half
    gx, gy = np.meshgrid(grid, grid)
    r = np.hypot(gx, gy)
    theta = np.arctan2(gy, gx)

    # Geometric descriptors on Frame 0 so dissipation follows the exact original anatomy
    edt = ndimage.distance_transform_edt(work_mask).astype(np.float32)
    local_max_edt = ndimage.maximum_filter(edt, size=15)
    spine_ratio = np.where(local_max_edt > 0.5, edt / (local_max_edt + 1e-4), 0.0)

    # Per-angle maximum outer radius of the original burst (rays recede cleanly toward real spike tips!)
    ang_bins = 720
    ang_idx = np.floor(((theta + math.pi) / (2.0 * math.pi)) * ang_bins).astype(np.int32) % ang_bins
    r_max_by_bin = np.zeros(ang_bins, dtype=np.float32)
    ys, xs = np.where(work_mask)
    if len(xs) > 0:
        b_idx = ang_idx[ys, xs]
        b_r = r[ys, xs]
        np.maximum.at(r_max_by_bin, b_idx, b_r)
    r_max_smooth = ndimage.gaussian_filter1d(r_max_by_bin, sigma=2.0, mode="wrap")
    r_outer_map = r_max_smooth[ang_idx]
    ray_t = np.clip((r - core_radius * 0.72) / np.maximum(16.0, r_outer_map - core_radius * 0.72), 0.0, 1.2)

    wave1 = _angular_wave(theta)
    wave2 = np.sin(theta * 11.0 - 0.7) * 0.55 + np.cos(theta * 17.0 + 1.4) * 0.45
    # Deterministic angular notch field for clean shard separation
    crack_field = (0.5 + 0.5 * wave1) * 0.62 + (0.5 + 0.5 * wave2) * 0.38

    frames_128: list[np.ndarray] = []

    # Frame 0: 100% faithful source burst from image copy 2.png
    frames_128.append(_downsample_crisp_128(work_mask, min_coverage=0.26))

    # Frames 1..6: Smooth kinetic expansion, cavity opening, clean fracture, base-to-tip recession (no dashed artifacts)
    # (exp_scale, push_px, cav_mul, cav_amp, crack_thr, min_edt, min_spine, tip_recede, cov_thr)
    stage_specs = [
        # F1: Snappy initial outward pop, hollow core widens noticeably, ring stays connected
        (1.040,  2.5, 1.44, 15.0, -9.00, 1.4, 0.34, 0.08, 0.28),
        # F2: Inner ring thins and opens first jagged fracture gaps; spikes stay crisp & long
        (1.080,  5.5, 1.82, 23.0,  0.31, 2.5, 0.50, 0.26, 0.30),
        # F3: Ring cleanly splits into flying crescent wedges & darting detached spikes
        (1.120,  8.5, 2.04, 27.0,  0.42, 3.0, 0.59, 0.44, 0.31),
        # F4: Crescent wedges shrink into sharp flying shards; spikes shorten cleanly from base toward tips
        (1.155, 11.5, 2.26, 29.0,  0.54, 3.4, 0.68, 0.58, 0.32),
        # F5: Only outer tapered dart tips & compact flying sparks remain
        (1.185, 14.5, 2.44, 28.0,  0.60, 3.5, 0.72, 0.66, 0.33),
        # F6: Final tiny crisp vanishing tip-sparks right before disappearing cleanly
        (1.210, 17.0, 2.70, 26.0,  0.72, 3.8, 0.78, 0.82, 0.35),
    ]

    for idx, (exp_scale, push_px, cav_mul, cav_amp, crack_thr, min_edt, min_spine, tip_recede, cov_thr) in enumerate(stage_specs, start=1):
        r_src = np.maximum(0.0, (r - push_px) / exp_scale)
        sx = half + r_src * np.cos(theta)
        sy = half + r_src * np.sin(theta)

        w_mask = ndimage.map_coordinates(work_mask.astype(np.float32), [sy, sx], order=1, mode="constant", cval=0.0) > 0.40
        w_edt = ndimage.map_coordinates(edt, [sy, sx], order=1, mode="constant", cval=0.0)
        w_spine = ndimage.map_coordinates(spine_ratio, [sy, sx], order=1, mode="constant", cval=0.0)
        w_ray_t = ndimage.map_coordinates(ray_t, [sy, sx], order=1, mode="constant", cval=0.0)

        # 1) Expanding organic hollow cavity
        cav_cut = (core_radius * cav_mul) + cav_amp * wave1 + (cav_amp * 0.42) * wave2
        outside_cavity = r >= cav_cut

        # 2) Clean angular fracture gaps (outer spike tips detach rather than shattering into dashes)
        if crack_thr > -5.0:
            eff_crack_thr = crack_thr - 0.32 * np.clip((w_ray_t - 0.55) / 0.45, 0.0, 1.0)
            not_cracked = crack_field >= eff_crack_thr
        else:
            not_cracked = np.ones_like(w_mask, dtype=bool)

        # 3) Spine-preserving thinning + base-to-tip recession along every ray
        # Rays shorten smoothly from their inner base toward their outer tip (no periodic dashed lines!)
        local_min_edt = min_edt * (1.0 - 0.56 * np.clip((w_ray_t - 0.52) / 0.48, 0.0, 1.0))
        keep_body = (w_edt >= local_min_edt) & ((w_spine >= min_spine) | (w_edt >= local_min_edt * 1.85))
        # Outer darts recede monotonically along w_ray_t >= tip_recede so each ray stays a single clean tapered dart
        keep_dart_tips = (
            (w_ray_t >= tip_recede)
            & (w_spine >= max(0.36, min_spine - 0.14))
            & (w_edt >= np.maximum(0.65, local_min_edt * 0.52))
        )

        # In the final 2 dissipation frames, dissolve inner body remnants and leave only clean outer receding tips & sparks
        if idx >= 5:
            frame_work = w_mask & outside_cavity & not_cracked & keep_dart_tips
        else:
            frame_work = w_mask & outside_cavity & not_cracked & (keep_body | keep_dart_tips)

        # Filter tiny 1-pixel workspace noise specs so every remaining shard reads cleanly in 128x128
        if idx >= 4:
            lbl, n_cc = ndimage.label(frame_work)
            if n_cc > 0:
                sizes = ndimage.sum(frame_work, lbl, range(1, n_cc + 1))
                min_cc = 10 if idx == 4 else (9 if idx == 5 else 6)
                keep_ids = [i + 1 for i, sz in enumerate(sizes) if sz >= min_cc]
                frame_work = np.isin(lbl, keep_ids) if keep_ids else np.zeros_like(frame_work)

        frame_128 = _downsample_crisp_128(frame_work, min_coverage=cov_thr)
        frames_128.append(frame_128)

    return frames_128


def save_atlas_and_tres(frames: list[np.ndarray], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    atlas_w = FRAME_SIZE * len(frames)
    atlas_h = FRAME_SIZE
    atlas = np.zeros((atlas_h, atlas_w, 4), dtype=np.uint8)

    for idx, mask in enumerate(frames):
        rgba = np.zeros((FRAME_SIZE, FRAME_SIZE, 4), dtype=np.uint8)
        # Pure crisp white (#FFFFFF) matching image copy 2.png, 100% hard binary alpha (0 or 255)
        rgba[mask, 0] = 255
        rgba[mask, 1] = 255
        rgba[mask, 2] = 255
        rgba[mask, 3] = 255
        atlas[:, idx * FRAME_SIZE : (idx + 1) * FRAME_SIZE, :] = rgba

    atlas_path = out_dir / "hit_impact-atlas-00.png"
    Image.fromarray(atlas, mode="RGBA").save(atlas_path, optimize=True)

    # Godot 4 SpriteFrames at 60Hz ticks: [3, 3, 3, 3, 3, 2, 2] = 19 ticks (~0.317s natural playback)
    durations = [3.0, 3.0, 3.0, 3.0, 3.0, 2.0, 2.0]
    lines = [
        f'[gd_resource type="SpriteFrames" load_steps={len(frames) + 2} format=3]',
        "",
        '[ext_resource type="Texture2D" path="res://assets/fx/hit_impact/hit_impact-atlas-00.png" id="1_atlas"]',
        "",
    ]
    for i in range(len(frames)):
        lines.extend([
            f'[sub_resource type="AtlasTexture" id="AtlasTexture_hit_{i}"]',
            'atlas = ExtResource("1_atlas")',
            f"region = Rect2({i * FRAME_SIZE}, 0, {FRAME_SIZE}, {FRAME_SIZE})",
            "",
        ])
    lines.append("[resource]")
    lines.append("animations = [{")
    lines.append('"frames": [{')
    for i, dur in enumerate(durations):
        lines.append(f'"duration": {dur:.1f},')
        lines.append(f'"texture": SubResource("AtlasTexture_hit_{i}")')
        if i < len(frames) - 1:
            lines.append("}, {")
        else:
            lines.append("}],")
    lines.append('"loop": false,')
    lines.append('"name": &"hit",')
    lines.append('"speed": 60.0')
    lines.append("}]")
    lines.append("")

    tres_path = out_dir / "hit_impact.tres"
    tres_path.write_text("\n".join(lines), encoding="utf-8")
    return atlas_path, tres_path


def render_3bg_filmstrip(atlas_path: Path, out_strip: Path, zoom: int = 2) -> None:
    """Render mandatory 3-background QA filmstrip (dark, sand/light, checkerboard) for visual audit."""
    atlas = Image.open(atlas_path).convert("RGBA")
    n = atlas.width // FRAME_SIZE
    cell = FRAME_SIZE * zoom
    pad = 8
    header_h = 26
    row_h = cell + pad * 2
    total_w = n * (cell + pad) + pad
    total_h = header_h + 3 * row_h

    sheet = Image.new("RGBA", (total_w, total_h), (18, 22, 28, 255))
    draw = ImageDraw.Draw(sheet)

    bg_specs = [
        ("DARK", lambda w, h: Image.new("RGBA", (w, h), (18, 20, 26, 255))),
        ("SAND/LIGHT", lambda w, h: Image.new("RGBA", (w, h), (196, 166, 118, 255))),
        ("CHECKER", None),
    ]

    for row_idx, (label, bg_fn) in enumerate(bg_specs):
        y_top = header_h + row_idx * row_h + pad
        for i in range(n):
            frame = atlas.crop((i * FRAME_SIZE, 0, (i + 1) * FRAME_SIZE, FRAME_SIZE))
            frame_z = frame.resize((cell, cell), Image.Resampling.NEAREST)
            x_left = pad + i * (cell + pad)
            if bg_fn is not None:
                tile = bg_fn(cell, cell)
            else:
                tile = Image.new("RGBA", (cell, cell), (110, 116, 126, 255))
                td = ImageDraw.Draw(tile)
                sq = 16
                for yy in range(0, cell, sq):
                    for xx in range(0, cell, sq):
                        if ((xx // sq) + (yy // sq)) % 2 == 0:
                            td.rectangle([xx, yy, xx + sq - 1, yy + sq - 1], fill=(156, 162, 172, 255))
            if row_idx == 2:
                td = ImageDraw.Draw(tile)
                c = cell // 2
                td.line([(c - 6, c), (c + 6, c)], fill=(255, 64, 64, 180), width=1)
                td.line([(c, c - 6), (c, c + 6)], fill=(255, 64, 64, 180), width=1)
            tile.alpha_composite(frame_z)
            sheet.paste(tile, (x_left, y_top))
            if row_idx == 0:
                px_cnt = int((np.array(frame)[..., 3] > 0).sum())
                draw.text((x_left + 4, 6), f"F{i} ({px_cnt}px)", fill=(235, 240, 248, 255))
        draw.text((pad + 2, y_top + 2), label, fill=(255, 220, 90, 255))

    out_strip.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_strip)


def main() -> int:
    ap = argparse.ArgumentParser(description="Build canonical hit_impact SpriteFrames from image copy 2.png")
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    ap.add_argument("--filmstrip", type=Path, default=None)
    args = ap.parse_args()

    work_mask, core_radius = extract_centered_work_mask(args.source)
    frames = build_frames(work_mask, core_radius)
    atlas_path, tres_path = save_atlas_and_tres(frames, args.out_dir)

    atlas_arr = np.array(Image.open(atlas_path).convert("RGBA"))
    alpha = atlas_arr[..., 3]
    hard_pct = 100.0 * float(((alpha == 0) | (alpha == 255)).mean())
    counts = [int(m.sum()) for m in frames]
    ratios = [round(100.0 * c / max(1, counts[0]), 1) for c in counts]
    border_clipped = any(
        bool(m[0, :].any() or m[-1, :].any() or m[:, 0].any() or m[:, -1].any())
        for m in frames
    )
    print(f"Atlas: {atlas_path} ({atlas_arr.shape[1]}x{atlas_arr.shape[0]}, 1 page)")
    print(f"SpriteFrames: {tres_path}")
    print(f"alpha_hardness_pct={hard_pct:.2f}% border_clipped={border_clipped}")
    print(f"Frame opaque px: {counts} (ratios vs F0: {ratios}%)")

    if args.filmstrip is not None:
        render_3bg_filmstrip(atlas_path, args.filmstrip)
        print(f"Filmstrip: {args.filmstrip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
