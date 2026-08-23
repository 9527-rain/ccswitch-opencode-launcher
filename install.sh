#!/usr/bin/env sh
set -eu

RELEASE_TAG=v0.2.0
RAW_BASE=${CCSWITCH_LAUNCHER_RAW_BASE:-https://raw.githubusercontent.com/9527-rain/ccswitch-opencode-launcher/$RELEASE_TAG}
INSTALL_DIR=${OPENCODE_CCSWITCH_INSTALL_DIR:-${XDG_BIN_HOME:-"$HOME/.local/bin"}}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [ ! -f "$SOURCE_DIR/opencode-ccswitch.py" ]; then
  command -v curl >/dev/null 2>&1 || { echo "curl is required for remote installation" >&2; exit 1; }
  TMP_DIR=$(mktemp -d)
  for file in opencode-ccswitch.py opencode-ccswitch; do
    curl -fsSL "$RAW_BASE/$file" -o "$TMP_DIR/$file"
  done
  SOURCE_DIR=$TMP_DIR
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
chmod +x "$INSTALL_DIR/opencode-ccswitch.py" "$INSTALL_DIR/opencode-ccswitch"
echo "Installed opencode-ccswitch to $INSTALL_DIR"
case ":${PATH:-}:" in *:"$INSTALL_DIR":*) ;; *) echo "Add this directory to PATH: export PATH=\"$INSTALL_DIR:\$PATH\"" ;; esac
