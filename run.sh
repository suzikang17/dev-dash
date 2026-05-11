#!/bin/bash
set -e
swift build
pkill -x DevDash 2>/dev/null || true
sleep 0.3
rm -f DevDash.app/Contents/MacOS/DevDash
cp .build/debug/DevDash DevDash.app/Contents/MacOS/DevDash
# Copy SPM-bundled JS resources into the .app's standard Resources/ folder.
# ProductDocAssets falls back to Bundle.main when Bundle.module is unavailable
# (which is the case for packaged .apps built via the cp-binary-into-app trick).
mkdir -p DevDash.app/Contents/Resources
cp .build/debug/DevDash_DevDash.bundle/Resources/alpine.min.js DevDash.app/Contents/Resources/
cp .build/debug/DevDash_DevDash.bundle/Resources/devdash-components.js DevDash.app/Contents/Resources/
codesign --force --deep --sign "Apple Development: sukisoap@icloud.com (L5PTDF7GUW)" DevDash.app
open DevDash.app
