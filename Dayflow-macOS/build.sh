#!/usr/bin/env bash
# Build dayflow native macOS app and wrap in a .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dayflow"
BUNDLE_ID="com.swryu.dayflow"
EXEC_NAME="DayflowApp"
APP_DIR="${APP_NAME}.app"

echo "==> swift build (release)"
swift build -c release

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp ".build/release/${EXEC_NAME}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>swryu</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ad-hoc sign so the binary launches without quarantine fuss
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> built ${APP_DIR}"

# install into /Applications so Launchpad picks it up
INSTALL_DIR="/Applications/${APP_DIR}"
if [[ -w /Applications || -w "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    cp -R "${APP_DIR}" "${INSTALL_DIR}"
    echo "==> installed to ${INSTALL_DIR}"
else
    echo "    (skipped /Applications install — not writable, run with sudo if needed)"
fi
echo "    open ${INSTALL_DIR}"
