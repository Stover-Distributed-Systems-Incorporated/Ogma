#!/bin/bash
# ── Ogma package builder ─────────────────────────────────────────
# Usage: bash build-pkg.sh <version>    (e.g. bash build-pkg.sh 2.0.0)
#
# Builds a distributable macOS installer package:
#   1. Compiles Ogma.swift + ogma-audio.swift as universal binaries
#      (arm64 + x86_64, macOS 13+)
#   2. Assembles Ogma.app with the helper scripts bundled in
#      Contents/Resources/scripts (the app installs them into
#      ~/.local/bin on first launch — see syncBundledResources)
#   3. Ad-hoc code-signs the bundle
#   4. Wraps it in a .pkg that installs to /Applications
#
# Output: dist/Ogma-<version>.pkg and dist/Ogma.pkg (stable name)
#
# The pkg is NOT notarized (no Developer ID) — downloaders must
# approve it once via System Settings → Privacy & Security.

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: bash build-pkg.sh <version>" >&2
    echo "Example: bash build-pkg.sh 2.0.0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$SCRIPT_DIR/dist"
IDENTIFIER="com.ogma.app"
MIN_OS="13.0"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

APP="$STAGE/root/Applications/Ogma.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts"

# ── 1. Universal binaries ────────────────────────────────────────
build_universal() {   # $1 = source file, $2 = output path
    local src="$1" out="$2"
    xcrun swiftc "$src" -O -target "arm64-apple-macos$MIN_OS"  -o "$out.arm64"
    xcrun swiftc "$src" -O -target "x86_64-apple-macos$MIN_OS" -o "$out.x86_64"
    lipo -create "$out.arm64" "$out.x86_64" -output "$out"
    rm -f "$out.arm64" "$out.x86_64"
}

echo "Compiling Ogma (universal)…"
build_universal "$SCRIPT_DIR/Ogma.swift" "$APP/Contents/MacOS/Ogma"

echo "Compiling ogma-audio (universal)…"
build_universal "$SCRIPT_DIR/ogma-audio.swift" "$APP/Contents/Resources/scripts/ogma-audio"

# ── 2. Bundle helper scripts ─────────────────────────────────────
for f in speak.sh normalize.py tts_server.py stt_server.py \
         install-local.sh uninstall.command; do
    cp "$SCRIPT_DIR/$f" "$APP/Contents/Resources/scripts/$f"
    chmod 755 "$APP/Contents/Resources/scripts/$f"
done

# ── 3. Info.plist ────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Ogma</string>
    <key>CFBundleIdentifier</key>
    <string>$IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>Ogma</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Ogma uses the microphone for local dictation (speech to text).</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# ── 4. App icon ──────────────────────────────────────────────────
# "OGMA" in Ogham script (read bottom-to-top) on a stemline:
# O = 2 level strokes, G = 2 slanted, M = 1 slanted, A = 1 level.
echo "Generating app icon…"
_ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$_ICONSET"
_ICONSCRIPT="$STAGE/genicon.swift"
cat > "$_ICONSCRIPT" << 'SWIFT_END'
import AppKit
let dir = CommandLine.arguments[1]
func px(_ n: Int) -> Data? {
    let s = CGFloat(n)
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.addPath(CGPath(roundedRect: CGRect(x:0, y:0, width:s, height:s),
        cornerWidth:s*0.22, cornerHeight:s*0.22, transform:nil))
    ctx.clip()
    let colors = [CGColor(red:0.043, green:0.208, blue:0.161, alpha:1),
                  CGColor(red:0.102, green:0.373, blue:0.294, alpha:1)]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x:s/2, y:0),
                           end: CGPoint(x:s/2, y:s), options: [])
    ctx.setStrokeColor(CGColor(red:0.949, green:0.918, blue:0.827, alpha:1))
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.052)
    ctx.move(to: CGPoint(x:s/2, y:s*0.16))
    ctx.addLine(to: CGPoint(x:s/2, y:s*0.84))
    ctx.strokePath()
    ctx.setLineWidth(s * 0.045)
    let half = s * 0.17, slant = s * 0.055
    func cross(_ y: CGFloat, _ diagonal: Bool) {
        let dy: CGFloat = diagonal ? slant : 0
        ctx.move(to: CGPoint(x:s/2 - half, y:y - dy))
        ctx.addLine(to: CGPoint(x:s/2 + half, y:y + dy))
        ctx.strokePath()
    }
    cross(s*0.245, false); cross(s*0.335, false)   // O
    cross(s*0.455, true);  cross(s*0.545, true)    // G
    cross(s*0.665, true)                           // M
    cross(s*0.775, false)                          // A
    guard let ci = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage:ci).representation(using:.png, properties:[:])
}
for (n,name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),
    (64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),
    (256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    if let d = px(n) { try? d.write(to:URL(fileURLWithPath:"\(dir)/\(name).png")) }
}
SWIFT_END
xcrun swift "$_ICONSCRIPT" "$_ICONSET"
if ! iconutil -c icns "$_ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "iconutil rejected the generated iconset; using the bundled fallback icon."
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ── 5. Ad-hoc code sign ──────────────────────────────────────────
# Strip extended attributes first so the payload carries no AppleDouble
# (._*) sidecar entries.
xattr -cr "$STAGE/root"
codesign --force --sign - "$APP/Contents/Resources/scripts/ogma-audio"
codesign --force --sign - "$APP"

# ── 6. Build the pkg ─────────────────────────────────────────────
mkdir -p "$DIST" "$STAGE/pkgscripts" "$STAGE/pkgres"

# Launch the app for the console user once installation finishes, so
# first-run onboarding starts immediately.
cat > "$STAGE/pkgscripts/postinstall" << 'POST'
#!/bin/bash
uid=$(stat -f%u /dev/console 2>/dev/null) || exit 0
user=$(stat -f%Su /dev/console 2>/dev/null) || exit 0
if [ -n "$user" ] && [ "$user" != "root" ]; then
    launchctl asuser "$uid" sudo -u "$user" open /Applications/Ogma.app 2>/dev/null || true
fi
exit 0
POST
chmod 755 "$STAGE/pkgscripts/postinstall"

pkgbuild \
    --root "$STAGE/root" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    --scripts "$STAGE/pkgscripts" \
    "$STAGE/ogma-component.pkg" > /dev/null

cp "$SCRIPT_DIR/LICENSE" "$STAGE/pkgres/LICENSE.txt"

cat > "$STAGE/distribution.xml" << DIST_XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Ogma $VERSION</title>
    <license file="LICENSE.txt"/>
    <options customize="never" hostArchitectures="arm64,x86_64"/>
    <allowed-os-versions>
        <os-version min="$MIN_OS"/>
    </allowed-os-versions>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="ogma"/>
    </choices-outline>
    <choice id="ogma" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">ogma-component.pkg</pkg-ref>
</installer-gui-script>
DIST_XML

productbuild \
    --distribution "$STAGE/distribution.xml" \
    --package-path "$STAGE" \
    --resources "$STAGE/pkgres" \
    "$DIST/Ogma-$VERSION.pkg" > /dev/null

cp "$DIST/Ogma-$VERSION.pkg" "$DIST/Ogma.pkg"

echo ""
echo "Built:"
echo "  $DIST/Ogma-$VERSION.pkg"
echo "  $DIST/Ogma.pkg (stable name for releases/latest/download)"
