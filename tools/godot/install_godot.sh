#!/usr/bin/env bash
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.7.2-stable}"
INSTALL_TEMPLATES="${INSTALL_TEMPLATES:-0}"
for arg in "$@"; do
  case "$arg" in
    --with-templates)
      INSTALL_TEMPLATES=1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="Godot_v${GODOT_VERSION}_linux.x86_64"
BIN_PATH="${SCRIPT_DIR}/${BIN_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Downloading ${BIN_NAME}..."
  curl -fL -o "${SCRIPT_DIR}/godot4.zip" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${BIN_NAME}.zip"
  unzip -qo "${SCRIPT_DIR}/godot4.zip" -d "${SCRIPT_DIR}/"
  rm -f "${SCRIPT_DIR}/godot4.zip"
  chmod +x "${BIN_PATH}"
fi

ln -sf "${BIN_PATH}" "${SCRIPT_DIR}/godot"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n ln -sf "${BIN_PATH}" /usr/local/bin/godot || true
  sudo -n ln -sf "${BIN_PATH}" /usr/local/bin/godot4 || true
fi

if [[ "${INSTALL_TEMPLATES}" == "1" ]]; then
  TEMPLATE_VERSION="${GODOT_VERSION/-/.}"
  TEMPLATE_DIR="${HOME}/.local/share/godot/export_templates/${TEMPLATE_VERSION}"
  if [[ ! -f "${TEMPLATE_DIR}/web_nothreads_release.zip" ]]; then
    echo "Downloading Godot ${GODOT_VERSION} export templates..."
    mkdir -p "${TEMPLATE_DIR}"
    TMP_TPZ="$(mktemp /tmp/godot_templates_XXXXXX.tpz)"
    trap 'rm -f "${TMP_TPZ}"' EXIT
    curl -fL -o "${TMP_TPZ}" \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_export_templates.tpz"
    unzip -qo -j "${TMP_TPZ}" 'templates/*' -d "${TEMPLATE_DIR}/"
    rm -f "${TMP_TPZ}"
    trap - EXIT
    echo "[OK] Godot export templates installed at ${TEMPLATE_DIR}"
  fi
fi

"${SCRIPT_DIR}/godot" --version
