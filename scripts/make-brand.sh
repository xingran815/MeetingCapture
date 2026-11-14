#!/usr/bin/env bash
# Writes the brand sources in packaging/brand/ and renders packaging/AppIcon.icns from them.
#
# The mark is "Prompt Bubble" (D-101): a speech bubble (the meeting) holding a shell prompt
# (the terminal). The menu bar glyphs are template images: black only, macOS tints them.
# Their state is in the shape, so they still read with color removed:
#   idle >_   recording ●   paused ‖   processing ···
#
#   scripts/make-brand.sh            → SVG sources + AppIcon.icns (needs only macOS tools)
set -euo pipefail
cd "$(dirname "$0")/.."

out=packaging/brand
mkdir -p "$out"

mark() { # $1 = colour
    printf '<path d="M6 8 H58 V44 H24 L12 56 V44 H6 Z" fill="none" stroke="%s" stroke-width="5" stroke-linecap="square" stroke-linejoin="miter"/>' "$1"
    printf '<path d="M16 17 L26 25.5 L16 34" fill="none" stroke="%s" stroke-width="5" stroke-linecap="square" stroke-linejoin="miter"/>' "$1"
    printf '<rect x="30" y="30" width="16" height="4.5" fill="%s"/>' "$1"
}

for v in phosphor:#4dff9a paper:#0b6a33; do
    name="${v%%:*}" colour="${v#*:}"
    {
        echo '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
        mark "$colour"
        echo
        echo '</svg>'
    } >"$out/mark-$name.svg"
done

# App icon on the 1024 grid: an 824 rounded square, phosphor mark, faint scanlines.
{
    echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    echo '<rect x="100" y="100" width="824" height="824" rx="185" fill="#0d120f"/>'
    for ((y = 108; y < 916; y += 8)); do
        printf '<rect x="110" y="%d" width="804" height="2" fill="#4dff9a" fill-opacity="0.05"/>' "$y"
    done
    echo
    echo '<rect x="102" y="102" width="820" height="820" rx="183" fill="none" stroke="#2a3a2f" stroke-width="4"/>'
    printf '<g transform="translate(224 236) scale(9)">'
    mark '#4dff9a'
    echo '</g>'
    echo '</svg>'
} >"$out/app-icon.svg"

# The macOS 26 icon (Icon Composer format): a solid fill and the mark as one layer. The
# system draws the shape and the glass; an .icns alone is shrunk onto a grey plate on
# macOS 26. build-app.sh compiles it with actool when Xcode is there.
icon=packaging/AppIcon.icon
mkdir -p "$icon/Assets"
{
    echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    printf '<g transform="translate(112 112) scale(12.5)">'
    mark '#4dff9a'
    echo '</g>'
    echo '</svg>'
} >"$icon/Assets/mark.svg"
cat >"$icon/icon.json" <<'JSON'
{
  "fill" : { "solid" : "srgb:0.05098,0.07059,0.05882,1.00000" },
  "groups" : [ { "layers" : [ { "image-name" : "mark.svg", "name" : "mark" } ] } ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON

bubble='<path d="M1.6 2 H16.4 V12.4 H7.2 L3.9 15.8 V12.4 H1.6 Z" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter"/>'
glyph() { # $1 = state, $2 = inner shapes
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">%s%s</svg>\n' \
        "$bubble" "$2" >"$out/menubar-$1.svg"
}
glyph idle '<path d="M4.5 4.7 L7.5 7.2 L4.5 9.7" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter"/><rect x="8.6" y="8.8" width="4.6" height="1.4" fill="#000"/>'
glyph recording '<circle cx="9" cy="7.2" r="2.8" fill="#000"/>'
glyph paused '<rect x="6.8" y="4.5" width="1.6" height="5.4" fill="#000"/><rect x="9.6" y="4.5" width="1.6" height="5.4" fill="#000"/>'
glyph processing '<rect x="5" y="6.5" width="1.6" height="1.6" fill="#000"/><rect x="8.2" y="6.5" width="1.6" height="1.6" fill="#000"/><rect x="11.4" y="6.5" width="1.6" height="1.6" fill="#000" fill-opacity="0.4"/>'

# Render the icon set with AppKit (NSImage reads SVG), then pack it with iconutil.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
set="$tmp/AppIcon.iconset"
mkdir -p "$set"
cat >"$tmp/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]) else { FileHandle.standardError.write("cannot read SVG\n".data(using: .utf8)!); exit(1) }
let px = Int(args[2])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
SWIFT
swiftc -O "$tmp/render.swift" -o "$tmp/render" 2>/dev/null
for s in 16 32 128 256 512; do
    "$tmp/render" "$out/app-icon.svg" "$s" "$set/icon_${s}x${s}.png"
    "$tmp/render" "$out/app-icon.svg" "$((s * 2))" "$set/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set" -o packaging/AppIcon.icns
"$tmp/render" "$out/app-icon.svg" 512 "$out/app-icon-512.png"
echo "make-brand: $out/*.svg, $out/app-icon-512.png, packaging/AppIcon.icns"
