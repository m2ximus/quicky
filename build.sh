#!/bin/bash
# Builds build/Quicky.app. `./build.sh install` also copies it to /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build/Quicky.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Quicky "$app/Contents/MacOS/Quicky"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Quicky</string>
    <key>CFBundleIdentifier</key><string>dev.quicky.Quicky</string>
    <key>CFBundleName</key><string>Quicky</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# macOS ties the Screen Recording grant to the code signature. An ad-hoc signature changes on
# every build, so the grant is lost; a certificate named "Quicky Dev" keeps it stable.
if security find-identity -p codesigning 2>/dev/null | grep -q '"Quicky Dev"'; then
    codesign --force --sign "Quicky Dev" "$app"
else
    codesign --force --sign - "$app"
    # The old grant no longer matches this build; clear it so macOS asks again cleanly.
    tccutil reset ScreenCapture dev.quicky.Quicky >/dev/null 2>&1 || true
    echo "Signed ad-hoc: Screen Recording permission must be re-granted after each rebuild."
    echo "To avoid that, create a code-signing certificate named \"Quicky Dev\" in Keychain Access"
    echo "(Certificate Assistant > Create a Certificate > Self Signed Root, Code Signing) and rebuild."
fi
echo "Built $app"

if [ "${1:-}" = "install" ]; then
    pkill -x Quicky 2>/dev/null || true
    rm -rf /Applications/Quicky.app
    cp -R "$app" /Applications/Quicky.app
    open /Applications/Quicky.app
    echo "Installed and launched /Applications/Quicky.app"
fi
