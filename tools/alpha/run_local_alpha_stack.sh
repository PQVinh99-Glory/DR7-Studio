#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/.env" ]; then
  # Extract only Supabase base URL & anon key without printing secrets
  eval "$(python3 - <<'PY'
import pathlib, urllib.parse
env = {}
for line in pathlib.Path(".env").read_text(encoding="utf-8").splitlines():
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s: continue
    k, v = s.split("=", 1)
    env[k.strip()] = v.strip().strip('"').strip("'")
p = urllib.parse.urlparse(env.get("API_URL", ""))
if p.scheme and p.netloc:
    print(f'export DR7_SUPABASE_URL="{p.scheme}://{p.netloc}"')
if env.get("anon_public"):
    print(f'export DR7_SUPABASE_ANON_KEY="{env["anon_public"]}"')
PY
)"
fi

PORT="${DR7_WS_PORT:-8788}"
echo "[alpha-server] Starting real Godot 4.7.2 Headless Zone Server on ws://0.0.0.0:${PORT}..."
exec "$ROOT_DIR/tools/godot/godot" --headless --path "$ROOT_DIR" --script res://server/headless_zone_server.gd -- --host 0.0.0.0 --port "$PORT"
