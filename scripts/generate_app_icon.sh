#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRAND_DIR="$ROOT_DIR/Brand"
ICONSET_DIR="$BRAND_DIR/AppIcon.iconset"
ICNS_PATH="$BRAND_DIR/MeetTranscript.icns"
TMP_SWIFT="/tmp/meettranscript_icon.swift"
TMP_ICON_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ICON_DIR"
}
trap cleanup EXIT

mkdir -p "$ICONSET_DIR"

cat > "$TMP_SWIFT" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

@inline(__always)
func makeRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func drawIcon(size: Int, outputPath: String) throws {
    let dimension = CGFloat(size)
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw NSError(domain: "MeetTranscriptIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create CGContext"])
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: CGColor) {
        context.setFillColor(color)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.fillPath()
    }

    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, color: CGColor, lineWidth: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.strokePath()
    }

    fillRoundedRect(makeRect(0, 0, dimension, dimension), radius: dimension * 0.24, color: color(0.06, 0.09, 0.12))
    strokeRoundedRect(
        makeRect(dimension * 0.03, dimension * 0.03, dimension * 0.94, dimension * 0.94),
        radius: dimension * 0.2,
        color: color(0.16, 0.21, 0.27),
        lineWidth: max(2, dimension * 0.012)
    )

    let micColor = color(0.95, 0.64, 0.27)
    let transcriptColor = color(0.27, 0.76, 0.71)

    fillRoundedRect(makeRect(dimension * 0.24, dimension * 0.40, dimension * 0.18, dimension * 0.30), radius: dimension * 0.09, color: micColor)
    strokeRoundedRect(makeRect(dimension * 0.20, dimension * 0.36, dimension * 0.26, dimension * 0.38), radius: dimension * 0.13, color: micColor, lineWidth: dimension * 0.04)
    fillRoundedRect(makeRect(dimension * 0.32, dimension * 0.28, dimension * 0.02, dimension * 0.10), radius: dimension * 0.01, color: micColor)
    fillRoundedRect(makeRect(dimension * 0.26, dimension * 0.23, dimension * 0.14, dimension * 0.035), radius: dimension * 0.0175, color: micColor)

    fillRoundedRect(makeRect(dimension * 0.55, dimension * 0.60, dimension * 0.21, dimension * 0.055), radius: dimension * 0.0275, color: transcriptColor)
    fillRoundedRect(makeRect(dimension * 0.55, dimension * 0.50, dimension * 0.24, dimension * 0.055), radius: dimension * 0.0275, color: transcriptColor)
    fillRoundedRect(makeRect(dimension * 0.55, dimension * 0.40, dimension * 0.17, dimension * 0.055), radius: dimension * 0.0275, color: transcriptColor)
    fillRoundedRect(makeRect(dimension * 0.55, dimension * 0.30, dimension * 0.26, dimension * 0.055), radius: dimension * 0.0275, color: transcriptColor)

    guard let cgImage = context.makeImage() else {
        throw NSError(domain: "MeetTranscriptIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create CGImage"])
    }

    let outputURL = URL(fileURLWithPath: outputPath) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(outputURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "MeetTranscriptIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create image destination"])
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "MeetTranscriptIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not write PNG"])
    }
}

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]) else {
    fputs("Usage: swift meettranscript_icon.swift <size> <output>\n", stderr)
    exit(1)
}

do {
    try drawIcon(size: size, outputPath: args[2])
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(2)
}
SWIFT

declare -a ICON_SPECS=(
  "16 icon_16x16.png"
  "32 icon_16x16@2x.png"
  "32 icon_32x32.png"
  "64 icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

for spec in "${ICON_SPECS[@]}"; do
  size="${spec%% *}"
  name="${spec#* }"
  output="$ICONSET_DIR/$name"
  SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
  swift "$TMP_SWIFT" "$size" "$output"
done

# Build an .icns using tiff2icns to avoid iconutil conversion issues on newer macOS.
SOURCE_1024="$ICONSET_DIR/icon_512x512@2x.png"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$SOURCE_1024" --out "$TMP_ICON_DIR/$size.png" >/dev/null
  sips -s format tiff "$TMP_ICON_DIR/$size.png" --out "$TMP_ICON_DIR/$size.tiff" >/dev/null
done

tiffutil -cat \
  "$TMP_ICON_DIR/16.tiff" \
  "$TMP_ICON_DIR/32.tiff" \
  "$TMP_ICON_DIR/64.tiff" \
  "$TMP_ICON_DIR/128.tiff" \
  "$TMP_ICON_DIR/256.tiff" \
  "$TMP_ICON_DIR/512.tiff" \
  "$TMP_ICON_DIR/1024.tiff" \
  -out "$TMP_ICON_DIR/all.tiff" >/dev/null 2>/dev/null

tiff2icns "$TMP_ICON_DIR/all.tiff" "$ICNS_PATH"

echo "App icon generated:"
echo "  $ICNS_PATH"
