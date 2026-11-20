#!/usr/bin/env bash
set -euo pipefail

# DR7-Studio Cloud CLI Installer (Pha 1: Supabase + Cloudflare Workers/Pages)
# Idempotent script for GitHub Codespaces / Linux (x86_64 & arm64).
# Usage: bash tools/infra/install_cloud_clis.sh [--check-only]

CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then
  CHECK_ONLY=1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) SUPABASE_ARCH="amd64" ;;
  aarch64|arm64) SUPABASE_ARCH="arm64" ;;
  *)
    echo "[ERROR] Unsupported CPU architecture: $ARCH" >&2
    exit 1
    ;;
esac

INSTALL_BIN_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_BIN_DIR"
export PATH="${INSTALL_BIN_DIR}:${PATH}"

echo "=== [1/2] Supabase CLI ==="
if command -v supabase >/dev/null 2>&1; then
  echo "[OK] supabase đã cài: $(command -v supabase) ($(supabase --version))"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "[MISSING] supabase CLI chưa được cài đặt."
else
  echo "[INFO] Đang tải Supabase CLI (linux_${SUPABASE_ARCH})..."
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  # Try official GitHub release binary first; fallback to npm global/npx wrapper if GitHub API is rate-limited
  REL_URL="$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((a['browser_download_url'] for a in d.get('assets',[]) if a['name'].endswith('linux_${SUPABASE_ARCH}.tar.gz')), ''))" 2>/dev/null || true)"
  if [ -n "$REL_URL" ]; then
    curl -fSL "$REL_URL" -o "$TMP_DIR/supabase.tar.gz"
    tar -xzf "$TMP_DIR/supabase.tar.gz" -C "$TMP_DIR"
    install -m 0755 "$TMP_DIR/supabase" "$INSTALL_BIN_DIR/supabase"
    echo "[OK] Đã cài Supabase CLI vào $INSTALL_BIN_DIR/supabase ($(supabase --version))"
  elif command -v npm >/dev/null 2>&1; then
    echo "[WARN] GitHub API giới hạn rate limit — chuyển sang cài Supabase CLI qua npm..."
    npm install -g supabase
    echo "[OK] Đã cài Supabase CLI qua npm ($(supabase --version))"
  else
    echo "[ERROR] Không thể tải Supabase CLI (cần curl tới GitHub hoặc npm)." >&2
    exit 1
  fi
fi

echo "=== [2/2] Cloudflare Wrangler CLI ==="
if command -v wrangler >/dev/null 2>&1; then
  echo "[OK] wrangler đã cài: $(command -v wrangler) ($(wrangler --version))"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "[MISSING] wrangler CLI chưa được cài đặt."
else
  if ! command -v npm >/dev/null 2>&1; then
    echo "[ERROR] Cần Node.js/npm để cài Cloudflare Wrangler CLI." >&2
    exit 1
  fi
  echo "[INFO] Đang cài Cloudflare Wrangler CLI qua npm..."
  npm install -g wrangler
  echo "[OK] Đã cài Wrangler CLI ($(wrangler --version))"
fi

echo ""
echo "=== Tóm tắt kiểm tra CLI ==="
if command -v supabase >/dev/null 2>&1; then
  echo "  • supabase : $(command -v supabase) — $(supabase --version)"
else
  echo "  • supabase : CHƯA CÀI"
fi
if command -v wrangler >/dev/null 2>&1; then
  echo "  • wrangler : $(command -v wrangler) — $(wrangler --version)"
else
  echo "  • wrangler : CHƯA CÀI"
fi
echo ""
echo "Bước đăng nhập tiếp theo khi Owner sẵn sàng deploy Pha 1:"
echo "  1. supabase login && supabase link --project-ref <PROJECT_REF>"
echo "  2. wrangler login && wrangler whoami"
