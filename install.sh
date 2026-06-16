#!/usr/bin/env bash
set -e

REPO="https://raw.githubusercontent.com/gnad97/shell-kit/main"
INSTALL_DIR="$HOME/.shell-kit"
SCRIPT="$INSTALL_DIR/shell-kit.sh"

# ── Detect OS ──────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) remote_script="mac.sh" ;;
  Linux)  remote_script="linux.sh" ;;
  *)
    echo "Unsupported OS: $(uname -s)"
    exit 1
    ;;
esac

# ── Detect shell rc file ───────────────────────────────────────────────────────
case "$SHELL" in
  */zsh)  rc="$HOME/.zshrc" ;;
  */bash) rc="$HOME/.bashrc" ;;
  *)      rc="$HOME/.profile" ;;
esac

# ── Download script ────────────────────────────────────────────────────────────
echo "Detected OS: $(uname -s) → downloading $remote_script"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$REPO/$remote_script" -o "$SCRIPT"
echo "Saved to $SCRIPT"

# ── Write source line to rc file ──────────────────────────────────────────────
SOURCE_LINE="source $SCRIPT"
if grep -qF "$SOURCE_LINE" "$rc" 2>/dev/null; then
  echo "Already sourced in $rc — skipping"
else
  printf '\n# shell-kit\n%s\n' "$SOURCE_LINE" >> "$rc"
  echo "Added to $rc"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Done! Next steps:"
echo ""
echo "  1. Fill in your secrets:"
echo "       $SCRIPT"
echo "     → TELEPORT_PASSWORD"
echo "     → TELEPORT_TOTP_SECRET"
echo ""
echo "  2. Reload your shell:"
echo "       source $rc"
echo ""
