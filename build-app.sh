#!/bin/sh
# Builds Screenlet.app, a zip of it and a Homebrew cask:
#   ./build-app.sh   -> dist/Screenlet-<version>-macos.zip, dist/screenlet.rb
# CASK_URL sets where the cask downloads the zip (the local file by default).
# To install: brew tap-new <you>/screenlet, copy dist/screenlet.rb into its Casks,
#   brew install --cask <you>/screenlet/screenlet
#   xattr -dr com.apple.quarantine "/Applications/Screenlet.app"
# The app is signed ad hoc, not with a Developer ID, so Gatekeeper refuses it
# while quarantined.
set -e
cd "$(dirname "$0")"
version="$(cat VERSION)"
app="dist/Screenlet.app"

# One build per architecture, joined with lipo, because a universal
# swift build fails on Xcode 16.
for arch in arm64 x86_64; do swift build -c release --arch $arch --scratch-path .build/$arch; done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/Screenlet" \
    "$(swift build -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)/Screenlet" \
    "$(swift build -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)/Screenlet"
cp -R Resources/*.lproj "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Screenlet</string>
    <key>CFBundleDisplayName</key><string>Screenlet</string>
    <key>CFBundleIdentifier</key><string>com.davideloconte.screenlet</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Screenlet</string>
    <key>CFBundleIconFile</key><string>Screenlet</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- The menu bar and its window: no Dock icon. -->
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Screenlet finds your tablet on the network and sends your desktop to it.</string>
    <key>NSBonjourServices</key>
    <array><string>_screenlet._tcp</string></array>
</dict>
</plist>
EOF

# The icon, rendered from the SVG at every size macOS needs.
iconset="dist/Screenlet.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
cat > dist/icon.swift <<'EOF'
import AppKit
let svg = NSImage(contentsOfFile: "Resources/Screenlet.svg")!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[1])/\(name)"))
    }
}
EOF
swift dist/icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Screenlet.icns"
rm -rf "$iconset" dist/icon.swift

# An ad hoc signature identifies the app by its hash, which changes on every
# build and makes macOS ask for Screen Recording and Accessibility again.
# Requiring only the identifier keeps the permissions, though any app with
# this identifier would get them. A Developer ID signature fixes that.
codesign --force --sign - --requirements "=designated => identifier \"com.davideloconte.screenlet\"" "$app"
zip="dist/Screenlet-$version-macos.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"

cat > dist/screenlet.rb <<EOF
cask "screenlet" do
  version "$version"
  sha256 "$sha"

  url "${CASK_URL:-file://$PWD/$zip}"
  name "Screenlet"
  desc "Galaxy Tab as a second monitor, over Wi-Fi or the USB cable"
  homepage "https://github.com/DavideLoconte/Screenlet-macOS"

  depends_on macos: ">= :sequoia"

  app "Screenlet.app"

  zap trash: [
    "~/.config/screenlet",
    "~/Library/Logs/Screenlet.log",
    "~/Library/Preferences/com.davideloconte.screenlet.plist",
  ]
end
EOF
echo "$zip"
echo dist/screenlet.rb
