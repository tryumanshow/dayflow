#!/usr/bin/env bash
# Build Dayflow native macOS app and wrap in a .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dayflow"
BUNDLE_ID="com.swryu.dayflow"
EXEC_NAME="DayflowApp"
APP_DIR="${APP_NAME}.app"

# Version sourcing — precedence: env var → release-please manifest → git tag → fallback.
# release-please maintains `.release-please-manifest.json` at the repo root
# as the canonical version number, so CI and local builds read from the
# same place. CI overrides via DAYFLOW_VERSION env to skip the lookup.
MANIFEST_PATH="../.release-please-manifest.json"
if [[ -n "${DAYFLOW_VERSION:-}" ]]; then
    APP_VERSION="${DAYFLOW_VERSION}"
elif [[ -f "${MANIFEST_PATH}" ]] && command -v python3 >/dev/null 2>&1; then
    APP_VERSION="$(python3 -c "import json,sys; print(json.load(open('${MANIFEST_PATH}')).get('.', '0.0.0'))")"
elif command -v git >/dev/null 2>&1 && git describe --tags --abbrev=0 >/dev/null 2>&1; then
    APP_VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
else
    APP_VERSION="0.0.0"
fi

# Build number — monotonic integer from total commit count. Guarantees Apple
# won't reject updates with the same short version during development.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
else
    BUILD_NUMBER="1"
fi

echo "==> version ${APP_VERSION} (build ${BUILD_NUMBER})"
echo "==> swift build (release)"
swift build -c release

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp ".build/release/${EXEC_NAME}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"

# Copy SwiftPM-generated resource bundle (localized strings, anything
# placed under Sources/DayflowApp/Resources/) into the .app. The wrinkle
# is WHERE. SwiftPM's generated `Bundle.module` accessor looks for the
# bundle via `Bundle.main.bundleURL.appendingPathComponent(name)`. For a
# `.app` that resolves to `Dayflow.app/<name>.bundle` — i.e. at the root
# of the .app, NOT inside `Contents/Resources/`. If we only put it in
# Contents/Resources the accessor falls through to the hardcoded build-
# dir path and we miss localizations on a clean install. So we place it
# at the root. macOS tolerates this; Finder just doesn't enumerate it.
SPM_RESOURCE_BUNDLE=".build/release/${APP_NAME}App_${EXEC_NAME}.bundle"
if [ -d "$SPM_RESOURCE_BUNDLE" ]; then
    rm -rf "${APP_DIR}/${APP_NAME}App_${EXEC_NAME}.bundle"
    cp -R "$SPM_RESOURCE_BUNDLE" "${APP_DIR}/${APP_NAME}App_${EXEC_NAME}.bundle"
fi

# Regenerate .icns from the Pillow-based renderer and copy into Resources.
if command -v python3 >/dev/null 2>&1; then
    echo "==> rendering app icon"
    python3 tools/make_icon.py >/dev/null
    cp "Dayflow.icns" "${APP_DIR}/Contents/Resources/Dayflow.icns"
fi

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
    <key>CFBundleIconFile</key>
    <string>Dayflow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 tryumanshow. All rights reserved.</string>
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
