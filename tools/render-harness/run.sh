#!/bin/sh
# Builds the app's renderer sources for macOS and runs main.swift. Output and PNGs go to $OUT.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/Endless Drawing"
OUT="${OUT:-${TMPDIR:-/tmp}/endless-render-harness}"
mkdir -p "$OUT"
xcrun -sdk macosx metal -c "$S/Rendering/Shaders.metal" -o "$OUT/shaders.air"
xcrun -sdk macosx metallib "$OUT/shaders.air" -o "$OUT/default.metallib"
# UIKit/AppKit differ in one MTKView call; the app source stays iOS-only.
sed 's/view?.setNeedsDisplay()/view?.needsDisplay = true/' "$S/Rendering/MetalRenderer.swift" > "$OUT/MetalRenderer.mac.swift"
xcrun -sdk macosx swiftc -O -swift-version 6 -default-isolation MainActor -o "$OUT/harness" \
  "$ROOT/tools/render-harness/main.swift" "$S"/Domain/*.swift "$OUT/MetalRenderer.mac.swift" \
  "$S/Rendering/RoundGeometry.swift" "$S/Rendering/BrushGeometry.swift" "$S/Rendering/RenderSignposts.swift" \
  "$S/Networking/WireProtocol.swift" "$S/Networking/DrawingEnvironment.swift" "$S/Persistence/IdentityStore.swift"
cd "$OUT" && ./harness
