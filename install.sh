#!/usr/bin/env sh
set -eu

RELEASE_TAG=${CCSWITCH_LAUNCHER_VERSION:-v0.3.0}
INSTALL_DIR=${OPENCODE_CCSWITCH_INSTALL_DIR:-${XDG_BIN_HOME:-"$HOME/.local/bin"}}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=
TMP_DIR=
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ACTION=install
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      printf '%s\n' "Usage: install.sh [--latest|--uninstall] [--no-path-update]"
      exit 0
      ;;
    --latest) ACTION=latest ;;
    --uninstall) ACTION=uninstall ;;
    --no-path-update) NO_PATH_UPDATE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$ACTION" = latest ] && [ -z "${CCSWITCH_LAUNCHER_VERSION:-}" ]; then
  command -v curl >/dev/null 2>&1 || { echo "curl is required to resolve the latest release" >&2; exit 1; }
  RELEASE_TAG=$(curl -fsSL https://api.github.com/repos/9527-rain/ccswitch-opencode-launcher/releases/latest | sed -n 's/^[[:space:]]*"tag_name": "\([^"]*\)".*/\1/p' | head -n 1)
fi
case "$RELEASE_TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "Invalid release tag: $RELEASE_TAG" >&2; exit 1 ;; esac
RELEASE_BASE=${CCSWITCH_LAUNCHER_RELEASE_BASE:-https://github.com/9527-rain/ccswitch-opencode-launcher/releases/download/$RELEASE_TAG}

if [ "$ACTION" = uninstall ]; then
  rm -f "$INSTALL_DIR/opencode-ccswitch.py" "$INSTALL_DIR/opencode-ccswitch" "$INSTALL_DIR/install.sh"
  echo "Uninstalled opencode-ccswitch from $INSTALL_DIR"
  exit 0
fi

if [ "$ACTION" != latest ] && [ "$(basename -- "$0")" = "install.sh" ] && [ -f "$SCRIPT_DIR/opencode-ccswitch.py" ]; then
  SOURCE_DIR=$SCRIPT_DIR
else
  command -v curl >/dev/null 2>&1 || { echo "curl is required for remote installation" >&2; exit 1; }
  TMP_DIR=$(mktemp -d)
  command -v tar >/dev/null 2>&1 || { echo "tar is required for remote installation" >&2; exit 1; }
  ASSET_NAME="ccswitch-opencode-launcher-$RELEASE_TAG-unix.tar.gz"
  ARCHIVE="$TMP_DIR/$ASSET_NAME"
  curl -fsSL "$RELEASE_BASE/$ASSET_NAME" -o "$ARCHIVE"
  curl -fsSL "$RELEASE_BASE/checksums.txt" -o "$TMP_DIR/checksums.txt"
  EXPECTED=$(awk -v asset="$ASSET_NAME" '$2 == asset { print $1; exit }' "$TMP_DIR/checksums.txt")
  [ -n "$EXPECTED" ] || { echo "No SHA256 checksum was published for $ASSET_NAME" >&2; exit 1; }
  if command -v sha256sum >/dev/null 2>&1; then ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}'); elif command -v shasum >/dev/null 2>&1; then ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}'); else echo "sha256sum or shasum is required" >&2; exit 1; fi
  [ "$ACTUAL" = "$EXPECTED" ] || { echo "SHA256 verification failed for $ASSET_NAME" >&2; exit 1; }
  SOURCE_DIR="$TMP_DIR/payload"
  mkdir -p "$SOURCE_DIR"
  tar -xzf "$ARCHIVE" -C "$SOURCE_DIR"
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "Python 3 is required" >&2
  exit 1
fi
mkdir -p "$INSTALL_DIR"
cp "$SOURCE_DIR/opencode-ccswitch.py" "$INSTALL_DIR/opencode-ccswitch.py"
cp "$SOURCE_DIR/opencode-ccswitch" "$INSTALL_DIR/opencode-ccswitch"
cp "$SOURCE_DIR/install.sh" "$INSTALL_DIR/install.sh"
chmod +x "$INSTALL_DIR/opencode-ccswitch.py" "$INSTALL_DIR/opencode-ccswitch"
chmod +x "$INSTALL_DIR/install.sh"
echo "Installed opencode-ccswitch $RELEASE_TAG to $INSTALL_DIR"
if [ "${NO_PATH_UPDATE:-0}" != 1 ]; then
  case ":${PATH:-}:" in *:"$INSTALL_DIR":*) ;; *) echo "Add this directory to PATH: export PATH=\"$INSTALL_DIR:\$PATH\"" ;; esac
fi
