#!/bin/bash
set -e

echo "Building release..."
swift build -c release

pkill -x DevDash 2>/dev/null || true

rm -f DevDash.app/Contents/MacOS/DevDash
cp .build/release/DevDash DevDash.app/Contents/MacOS/DevDash

mkdir -p DevDash.app/Contents/Resources
cp .build/release/DevDash_DevDash.bundle/Resources/alpine.min.js DevDash.app/Contents/Resources/
cp .build/release/DevDash_DevDash.bundle/Resources/devdash-components.js DevDash.app/Contents/Resources/

# Ad-hoc sign — works on any Mac (first launch: right-click → Open to bypass Gatekeeper)
codesign --force --deep --sign - DevDash.app

OUTFILE="DevDash-$(date +%Y%m%d).zip"
zip -r "$OUTFILE" DevDash.app
echo "Done: $OUTFILE"
