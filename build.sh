#!/bin/zsh
# Builds Launchpad.app as a universal (Apple Silicon + Intel) binary.
#   ./build.sh            build into build/Launchpad.app
#   ./build.sh --install  also copy it into /Applications and launch it
#   ./build.sh --dmg      also package build/MacBook-Launchpad-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
APP=build/Launchpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Launchpad "$APP/Contents/MacOS/Launchpad"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
--install)
    pkill -x Launchpad 2>/dev/null || true
    rm -rf /Applications/Launchpad.app
    cp -R "$APP" /Applications/
    open /Applications/Launchpad.app
    echo "Installed to /Applications/Launchpad.app"
    ;;
--dmg)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    DMG="build/MacBook-Launchpad-$VERSION.dmg"
    STAGING=build/dmg
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "MacBook Launchpad" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGING"
    shasum -a 256 "$DMG"
    echo "Packaged $DMG"
    ;;
esac
