#!/bin/bash
# Builds the app, then dist/ChemClip-<version>.zip and dist/ChemClip.dmg for sharing.
# The disk image opens to a window with ChemClip, a reaction arrow and Applications. Laying it out asks Finder
# (macOS may ask once to allow Terminal to control Finder); without that the image still works, unstyled.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/ChemClip.app/Contents/Info.plist)"
name="ChemClip-$version"
volume="ChemClip $version"
rm -f "dist/$name.zip" "dist/ChemClip.dmg"

ditto -c -k --keepParent dist/ChemClip.app "dist/$name.zip"

work="$(mktemp -d)"
mount=""
cleanup() {
    [ -n "$mount" ] && hdiutil detach -quiet -force "$mount" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/stage" "$work/stage/.background"
cp -R dist/ChemClip.app "$work/stage/"
ln -s /Applications "$work/stage/Applications"
swift scripts/make-dmg-background.swift "$work/stage/.background/background.tiff"

hdiutil create -quiet -volname "$volume" -srcfolder "$work/stage" -fs HFS+ -format UDRW "$work/rw.dmg"
mount="$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" | awk -F'\t' '/\/Volumes\// { print $NF }')"
disk="$(basename "$mount")"

# Icon centers match scripts/make-dmg-background.swift.
osascript <<EOF || echo "Could not lay out the disk image window; it will open as a plain folder." >&2
tell application "Finder"
    tell disk "$disk"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "ChemClip.app" of container window to {160, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
SetFile -a V "$mount/.background" 2>/dev/null || true
rm -rf "$mount/.fseventsd"
sync
hdiutil detach -quiet "$mount"
mount=""
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "dist/ChemClip.dmg"

printf 'Packaged:\n  dist/%s.zip\n  dist/ChemClip.dmg\n' "$name"
