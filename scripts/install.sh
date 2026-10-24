#!/usr/bin/env bash
# Builds a release afm binary and links it into ~/.local/bin (no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product afm
BIN=$(swift build -c release --show-bin-path)
DEST="${AFM_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST" "$HOME/.local/share/afm-studio"
cp "$BIN/afm" "$HOME/.local/share/afm-studio/afm"
ln -sf "$HOME/.local/share/afm-studio/afm" "$DEST/afm"
echo "✓ afm installed: $DEST/afm"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "  Add $DEST to your PATH to use it from any shell.";; esac
echo "  Register with Claude Code:  claude mcp add --scope user afm -- \"$DEST/afm\" mcp"
