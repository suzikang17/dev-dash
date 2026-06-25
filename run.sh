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
# Compile Metal shaders into default.metallib so SwiftUI's ShaderLibrary.default
# (which reads from Bundle.main) finds them in the packaged .app. Requires the
# Metal Toolchain component: xcodebuild -downloadComponent MetalToolchain
xcrun metal -o DevDash.app/Contents/Resources/default.metallib Sources/DevDash/Shaders/*.metal
# Prefer the real Apple Development identity (needed for entitlements /
# distribution); fall back to ad-hoc signing on machines without it so local
# debug runs still work.
codesign --force --deep --sign "Apple Development: sukisoap@icloud.com (L5PTDF7GUW)" DevDash.app 2>/dev/null \
  || codesign --force --deep --sign - DevDash.app
open DevDash.app
