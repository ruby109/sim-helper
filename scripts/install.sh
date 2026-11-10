#!/bin/bash
# Builds sim-helper, installs it, and installs SimSlim, which `sim acquire` requires.
#
#   scripts/install.sh                     # installs to /usr/local/bin
#   BIN_DIR=~/.local/bin scripts/install.sh
set -euo pipefail

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SIMSLIM_FORMULA="mobai-app/tap/simslim"
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || fail "sim-helper only runs on macOS."
command -v simslim >/dev/null || command -v brew >/dev/null || fail "Homebrew is required to install SimSlim. See https://brew.sh"
mkdir -p "$BIN_DIR" 2>/dev/null || true
[[ -w "$BIN_DIR" ]] || fail "$BIN_DIR is not writable. Rerun with BIN_DIR set to a directory on your PATH, e.g. BIN_DIR=~/.local/bin $0"

echo "==> Building sim-helper"
swift build -c release

if command -v simslim >/dev/null; then
    echo "==> SimSlim already installed: $(command -v simslim)"
else
    echo "==> Installing SimSlim ($SIMSLIM_FORMULA)"
    brew install "$SIMSLIM_FORMULA"
fi

install -m 755 .build/release/sim-helper "$BIN_DIR/sim-helper"
echo "==> Installed $BIN_DIR/sim-helper"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH." ;;
esac
echo "To give agents the sim-helper skill:"
echo "  Claude Code: mkdir -p ~/.claude/skills && ln -s \"$PWD/skills/sim-helper\" ~/.claude/skills/sim-helper"
echo "  Codex:       mkdir -p ~/.agents/skills && ln -s \"$PWD/skills/sim-helper\" ~/.agents/skills/sim-helper"
