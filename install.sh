#!/bin/bash
# dev-dash installer — builds DevDash.app and sets up the `lore` CLI on PATH.
#
#   git clone git@github.com:suzikang17/dev-dash.git
#   cd dev-dash && bash install.sh
#
# Overridable via env: LORE_REPO, LORE_DIR, APP_DEST.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LORE_REPO="${LORE_REPO:-https://github.com/suzikang17/lore.git}"
LORE_DIR="${LORE_DIR:-$HOME/dev/lore}"
BIN_DIR="$HOME/.local/bin"
APP_DEST="${APP_DEST:-/Applications}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- prerequisites
say "Checking prerequisites"
have git   || { echo "✗ git/Xcode CLT missing — run: xcode-select --install"; exit 1; }
have swift || { echo "✗ swift missing — run: xcode-select --install"; exit 1; }
have node  || { echo "✗ node missing — install Node 20+ (brew install node, or fnm)"; exit 1; }
# Real node binary (resolves fnm/nvm shims to a stable absolute path the GUI can use).
NODE_BIN="$(node -e 'process.stdout.write(process.execPath)')"
echo "✓ node: $NODE_BIN"

if   have pnpm;     then PM="pnpm"
elif have corepack; then corepack enable >/dev/null 2>&1 || true; PM="corepack pnpm"
else PM=""; fi

# ------------------------------------------------------------- build DevDash.app
say "Building DevDash.app (release)"
cd "$REPO_DIR"
swift build -c release
pkill -x DevDash 2>/dev/null || true
rm -f DevDash.app/Contents/MacOS/DevDash
cp .build/release/DevDash DevDash.app/Contents/MacOS/DevDash
mkdir -p DevDash.app/Contents/Resources
cp .build/release/DevDash_DevDash.bundle/Resources/alpine.min.js        DevDash.app/Contents/Resources/
cp .build/release/DevDash_DevDash.bundle/Resources/devdash-components.js DevDash.app/Contents/Resources/
codesign --force --deep --sign - DevDash.app   # ad-hoc: runs on any Mac

if cp -R DevDash.app "$APP_DEST/" 2>/dev/null; then
  APP_PATH="$APP_DEST/DevDash.app"
else
  APP_PATH="$REPO_DIR/DevDash.app"
  echo "  (no write access to $APP_DEST — left app at $APP_PATH)"
fi
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
echo "✓ app: $APP_PATH"

# ------------------------------------------------------------------- set up lore
say "Setting up lore"
if [ -d "$LORE_DIR/.git" ]; then
  git -C "$LORE_DIR" pull --ff-only || true
else
  git clone "$LORE_REPO" "$LORE_DIR"
fi
cd "$LORE_DIR"
if [ -n "$PM" ]; then
  $PM install
  $PM -r build
else
  echo "✗ pnpm not found (lore is a pnpm monorepo). Install it: npm i -g pnpm — then re-run."
  exit 1
fi

# Wrapper on PATH that hardcodes node, so the GUI app (limited PATH) can run lore.
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/lore" <<EOF
#!/bin/sh
exec "$NODE_BIN" "$LORE_DIR/packages/cli/bin/lore.js" "\$@"
EOF
chmod +x "$BIN_DIR/lore"
echo "✓ lore: $BIN_DIR/lore -> $LORE_DIR/packages/cli/bin/lore.js"

# Ensure ~/.local/bin is on PATH for terminal use (the app already finds it absolutely).
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    RC="$HOME/.zshrc"
    if ! grep -qs 'local/bin' "$RC" 2>/dev/null; then
      printf '\n# dev-dash: lore CLI\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
      echo "✓ added ~/.local/bin to PATH in $RC (restart your shell)"
    fi
    ;;
esac

# ------------------------------------------------------------------------- done
say "Done"
echo "Launch:   open '$APP_PATH'    (first launch: right-click → Open)"
echo "lore:     $("$BIN_DIR/lore" --version 2>/dev/null || echo 'installed')"
echo
echo "Optional, for full features (per-user):"
echo "  • gh auth login      → PRs view"
echo "  • claude (logged in) → AI devlog/summary generation"
