#!/bin/bash
# Builds dist/ChemClip.app and dist/chemclip-tool.
# Universal (Apple silicon + Intel) when full Xcode is installed; otherwise the current architecture.
# Set CHEMCLIP_SIGN_IDENTITY to sign with a certificate instead of ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
version="1.0.0"
build_dir="${CHEMCLIP_BUILD_DIR:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
arch_flags=(--arch arm64 --arch x86_64)
if ! swift build -c release --disable-sandbox --scratch-path "$build_dir" "${arch_flags[@]}" 2>/dev/null; then
    echo "Universal build unavailable; building for $(uname -m) only."
    arch_flags=()
    swift build -c release --disable-sandbox --scratch-path "$build_dir"
fi
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox --scratch-path "$build_dir" ${arch_flags[@]+"${arch_flags[@]}"})"
app="$PWD/dist/ChemClip.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/ChemClip" "$app/Contents/MacOS/ChemClip"
cp "$bin_dir/chemclip-tool" "$PWD/dist/chemclip-tool"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ChemClip</string>
<key>CFBundleDisplayName</key><string>ChemClip</string>
<key>CFBundleIdentifier</key><string>local.chemclip.assistant</string>
<key>CFBundleExecutable</key><string>ChemClip</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Mosè Simone Galluzzo. MIT License.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp=none --sign "${CHEMCLIP_SIGN_IDENTITY:--}" "$app"
codesign --force --sign "${CHEMCLIP_SIGN_IDENTITY:--}" "$PWD/dist/chemclip-tool"
printf 'Built %s (%s, %s)\n' "$app" "$version" "$(lipo -archs "$app/Contents/MacOS/ChemClip")"
