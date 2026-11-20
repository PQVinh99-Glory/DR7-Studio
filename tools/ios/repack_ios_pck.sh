#!/usr/bin/env bash
set -euo pipefail

# Fast Linux Codespace iOS .pck repacker for DR7-Studio (pure GDScript, no GDExtension).
# Reuses 1 base unsigned .ipa built once by GitHub Actions (macos-latest), exports fresh
# Godot 4.7.2 iOS .pck on Linux, swaps it inside Payload/*.app/, and writes a new unsigned .ipa
# ready for Sideloadly / AltStore / SideStore.
#
# Usage:
#   bash tools/ios/repack_ios_pck.sh <base_ipa_path> [output_ipa_path]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_IPA="${1:-}"
APP_VER="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
RAW_OUT_IPA="${2:-$ROOT_DIR/build/ios/dr7-studio-v${APP_VER}-repacked-unsigned.ipa}"

if [ -z "$BASE_IPA" ] || [ ! -f "$BASE_IPA" ]; then
  echo "Cach dung: bash tools/ios/repack_ios_pck.sh <duong_dan_base.ipa> [output.ipa]" >&2
  echo "Lay base .ipa 1 lan tu GitHub Actions workflow 'Build iOS IPA' (signing_mode=unsigned_sideload)." >&2
  exit 1
fi

# Resolve output path to an absolute path before changing directories into TMP_DIR.
mkdir -p "$(dirname "$RAW_OUT_IPA")" "$ROOT_DIR/build"
OUT_IPA="$(cd "$(dirname "$RAW_OUT_IPA")" && pwd)/$(basename "$RAW_OUT_IPA")"

GODOT_BIN="$ROOT_DIR/tools/godot/godot"
TEMPLATE_DIR="$HOME/.local/share/godot/export_templates/4.7.2.stable"
if [ ! -x "$GODOT_BIN" ] || [ ! -f "$TEMPLATE_DIR/ios.zip" ]; then
  echo "[INFO] Khong thay Godot 4.7.2 local hoac iOS export template, dang tai..."
  bash "$ROOT_DIR/tools/godot/install_godot.sh" --with-templates
fi

touch "$ROOT_DIR/build/.gdignore"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[1/3] Xuat Godot 4.7.2 iOS pack (.pck) tren Linux..."
"$GODOT_BIN" --headless --path "$ROOT_DIR" --editor --import >/dev/null
"$GODOT_BIN" --headless --path "$ROOT_DIR" --export-pack "iOS" "$TMP_DIR/new_game.pck"

echo "[2/3] Giai nen base .ipa va thay the file .pck..."
unzip -q "$BASE_IPA" -d "$TMP_DIR/ipa_root"
APP_DIR="$(find "$TMP_DIR/ipa_root/Payload" -maxdepth 1 -name "*.app" -type d | head -n 1)"
if [ -z "$APP_DIR" ]; then
  echo "[ERROR] Khong tim thay Payload/*.app ben trong $BASE_IPA" >&2
  exit 1
fi

EXISTING_PCK="$(find "$APP_DIR" -maxdepth 1 -name "*.pck" -type f | head -n 1 || true)"
if [ -n "$EXISTING_PCK" ]; then
  cp "$TMP_DIR/new_game.pck" "$EXISTING_PCK"
else
  APP_BASENAME="$(basename "$APP_DIR" .app)"
  cp "$TMP_DIR/new_game.pck" "$APP_DIR/${APP_BASENAME}.pck"
fi
# Remove stale signature if base IPA had one so Sideloadly/AltStore/SideStore re-signs cleanly
rm -rf "$APP_DIR/_CodeSignature"

echo "[3/3] Nen lai unsigned .ipa tai $OUT_IPA..."
rm -f "$OUT_IPA"
(cd "$TMP_DIR/ipa_root" && zip -qry "$OUT_IPA" Payload)
sha256sum "$OUT_IPA" | tee "${OUT_IPA}.sha256"
echo "[OK] Hoan tat repack iOS .ipa: $OUT_IPA"
