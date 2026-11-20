#!/usr/bin/env python3
"""Generate an AltStore / SideStore compatible source.json feed for DR7-Studio iOS IPA."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build_source_payload(
    *,
    version: str,
    download_url: str,
    size_bytes: int,
    sha256_hex: str = "",
    bundle_id: str = "com.dr7studio.dragonball2d",
    source_url: str = "",
    icon_url: str = "",
    min_os_version: str = "15.0",
    release_date: str | None = None,
    description: str = "DR7-Studio DragonBall 2D iOS build (Godot 4.7.2 Compatibility, 60 FPS).",
) -> dict:
    iso_date = release_date or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    version_desc = f"DR7-Studio v{version} (iOS unsigned sideload build for Sideloadly / AltStore / SideStore)."
    if sha256_hex:
        version_desc += f" SHA-256: {sha256_hex[:16]}..."
    return {
        "name": "DR7-Studio iOS Sideload Source",
        "subtitle": "Official DR7-Studio test builds for AltStore & SideStore",
        "description": "Kenh cap nhat file .ipa test truc tiep cho AltStore & SideStore (0d) truoc khi chuyen sang TestFlight.",
        "identifier": f"{bundle_id}.source",
        "sourceURL": source_url,
        "iconURL": icon_url,
        "website": "https://github.com/Dev99-V/Dragonball-Studio-7",
        "tintColor": "#F97316",
        "featuredApps": [bundle_id],
        "apps": [
            {
                "name": "DR7-Studio DragonBall 2D",
                "bundleIdentifier": bundle_id,
                "developerName": "DR7-Studio",
                "subtitle": "2D Dragon Ball Action Sandbox (60 FPS)",
                "localizedDescription": description,
                "iconURL": icon_url,
                "tintColor": "#F97316",
                "category": "games",
                "versions": [
                    {
                        "version": version,
                        "date": iso_date,
                        "localizedDescription": version_desc,
                        "downloadURL": download_url,
                        "size": int(size_bytes),
                        "minOSVersion": min_os_version,
                        "sha256": sha256_hex,
                    }
                ],
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {},
                },
            }
        ],
        "news": [],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate AltStore/SideStore source.json for DR7-Studio")
    parser.add_argument("--version", required=True, help="App SemVer version (e.g. 0.16.0)")
    parser.add_argument("--ipa", type=Path, help="Path to built .ipa file to measure exact size & SHA-256")
    parser.add_argument("--size", type=int, default=0, help="Fallback byte size if --ipa is omitted")
    parser.add_argument("--download-url", required=True, help="HTTPS download URL for the .ipa file")
    parser.add_argument("--source-url", default="", help="Public HTTPS URL of this source.json")
    parser.add_argument("--icon-url", default="", help="Public HTTPS URL of app icon (512x512 PNG)")
    parser.add_argument("--bundle-id", default="com.dr7studio.dragonball2d")
    parser.add_argument("--output", type=Path, required=True, help="Output JSON file path")
    args = parser.parse_args(argv)

    size_bytes = args.size
    sha_hex = ""
    if args.ipa:
        if not args.ipa.is_file():
            raise SystemExit(f"[ERROR] IPA file not found: {args.ipa}")
        size_bytes = args.ipa.stat().st_size
        sha_hex = sha256_file(args.ipa)

    payload = build_source_payload(
        version=args.version,
        download_url=args.download_url,
        size_bytes=size_bytes,
        sha256_hex=sha_hex,
        bundle_id=args.bundle_id,
        source_url=args.source_url,
        icon_url=args.icon_url,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[OK] Generated AltStore/SideStore source JSON at {args.output} (v{args.version}, {size_bytes} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
