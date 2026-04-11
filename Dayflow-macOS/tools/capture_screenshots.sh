#!/usr/bin/env bash
# Capture Day / Week / Month / Settings screenshots for the README.
#
# Uses the native macOS accessibility stack (AXPress on the nav bar buttons
# plus `screencapture`) to drive the app — no Playwright, no third-party
# deps. Run this after every UI-visible change so `docs/screenshots/*.png`
# reflects the current build.
#
# Prerequisite: the app must be installed to /Applications/Dayflow.app
# (run `./build.sh` first). You'll also need to grant Terminal (or whatever
# shell you're running this from) accessibility permission the first time
# — System Settings → Privacy & Security → Accessibility.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="/Applications/Dayflow.app"
OUT_DIR="docs/screenshots"
mkdir -p "$OUT_DIR"

if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH missing — run ./build.sh first" >&2
    exit 1
fi

# Quit any existing instance so we always start from a clean state. The
# AppleScript quit call can't fail the script if the app isn't running.
osascript -e 'tell application id "com.swryu.dayflow" to quit' 2>/dev/null || true
sleep 2

open "$APP_PATH"
sleep 5

# Park the window at a predictable origin/size so the crop math is stable.
osascript <<'EOF'
tell application "System Events" to tell process "DayflowApp"
  set frontmost to true
  if (count of windows) > 0 then
    perform action "AXRaise" of window 1
    set position of window 1 to {80, 80}
    set size of window 1 to {1440, 920}
  end if
end tell
EOF
sleep 2

press_button() {
    local index="$1"
    osascript <<EOF
tell application "System Events" to tell process "DayflowApp"
  set btns to every button of group 1 of window 1
  perform action "AXPress" of (item $index of btns)
end tell
EOF
}

capture_to() {
    local name="$1"
    local raw="/tmp/dayflow-capture-$name.png"
    screencapture -x "$raw"
    python3 - <<PY
from PIL import Image
img = Image.open("$raw")
cropped = img.crop((160, 160, 160 + 2880, 160 + 1840))
cropped = cropped.resize((1440, 920), Image.LANCZOS)
cropped.save("$OUT_DIR/$name.png")
PY
    rm -f "$raw"
    echo "  captured: $OUT_DIR/$name.png"
}

# Button indices inside `group 1 of window 1`, in the order they appear
# on the nav bar:
#   1 Day tab   2 Week tab   3 Month tab   4 chevron-left
#   5 Today     6 chevron-right   7 refresh
press_button 1
sleep 0.3
press_button 5  # Today — guarantees Day view is showing the current date
sleep 2
capture_to day

press_button 2
sleep 2
capture_to week

press_button 3
sleep 2
capture_to month

# Settings window uses a separate capture path since it's a different window.
osascript <<'EOF'
tell application "System Events" to tell process "DayflowApp"
  set frontmost to true
  click menu item "Settings…" of menu 1 of menu bar item "Dayflow" of menu bar 1
end tell
EOF
sleep 3
osascript <<'EOF'
tell application "System Events" to tell process "DayflowApp"
  try
    set w to window "Dayflow Settings"
    perform action "AXRaise" of w
    set position of w to {500, 150}
  end try
end tell
EOF
sleep 2

raw="/tmp/dayflow-capture-settings.png"
screencapture -x "$raw"
python3 - <<'PY'
from PIL import Image
img = Image.open("/tmp/dayflow-capture-settings.png")
# Settings window: (500, 150) logical = (1000, 300) retina, width ~520.
# Crop generously (tall enough to include the System Prompt TextEditor
# and the save/reset buttons underneath) and downscale for the README.
crop = img.crop((960, 280, 2120, 1900))
target_w = 960
target_h = int(crop.size[1] * target_w / crop.size[0])
crop = crop.resize((target_w, target_h), Image.LANCZOS)
crop.save("docs/screenshots/settings.png")
PY
rm -f "$raw"
echo "  captured: $OUT_DIR/settings.png"

echo "==> all screenshots refreshed under $OUT_DIR/"
