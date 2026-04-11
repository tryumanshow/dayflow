#!/usr/bin/env bash
# Capture Day / Week / Month / Settings screenshots for the README,
# once per supported UI language.
#
# Uses the native macOS accessibility stack (AXPress on the nav bar buttons
# plus `screencapture`) to drive the app — no Playwright, no third-party
# deps. Runs the app twice: once with `-AppleLanguages '("en")'` and once
# with `'("ko")'`. Output lands under:
#     docs/screenshots/en/{day,week,month,settings}.png
#     docs/screenshots/ko/{day,week,month,settings}.png
#
# Prerequisite: the app must be installed to /Applications/Dayflow.app
# (run `./build.sh` first). Also grant Terminal accessibility permission
# the first time — System Settings → Privacy & Security → Accessibility.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="/Applications/Dayflow.app"
OUT_ROOT="docs/screenshots"

if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH missing — run ./build.sh first" >&2
    exit 1
fi

DB_DIR="${HOME}/Library/Application Support/Dayflow"
DB_PATH="${DB_DIR}/dayflow.db"
BACKUP_DIR="/tmp/dayflow-screenshot-backup"

# Back up the user's real DB before seeding demo content. Restored in a
# trap at exit so even if the script dies we don't leave their notes
# overwritten. We copy WAL + SHM too because the DB might be mid-checkpoint.
mkdir -p "$BACKUP_DIR"
rm -f "$BACKUP_DIR"/*
for suffix in "" "-wal" "-shm" "-journal"; do
    if [ -f "${DB_PATH}${suffix}" ]; then
        cp "${DB_PATH}${suffix}" "${BACKUP_DIR}/dayflow.db${suffix}"
    fi
done

BUNDLE_ID="com.swryu.dayflow"

# Snapshot the user's current AppleLanguages preference so we can restore
# it at the end — `defaults delete` is the cleanest way to fall back to
# "follow system language" if the user hadn't set one explicitly.
PRIOR_LANG="$(defaults read "$BUNDLE_ID" AppleLanguages 2>/dev/null || echo '__unset__')"

cleanup() {
    osascript -e 'tell application id "com.swryu.dayflow" to quit' 2>/dev/null || true
    sleep 1
    for suffix in "" "-wal" "-shm" "-journal"; do
        local src="${BACKUP_DIR}/dayflow.db${suffix}"
        local dst="${DB_PATH}${suffix}"
        if [ -f "$src" ]; then
            cp "$src" "$dst"
        else
            rm -f "$dst"
        fi
    done
    if [ "$PRIOR_LANG" = "__unset__" ]; then
        defaults delete "$BUNDLE_ID" AppleLanguages 2>/dev/null || true
    fi
    # else: leave whatever the user had. We don't try to re-encode the
    # plist back via `defaults write` because the pre-existing value may
    # be a multi-entry array and we only read the first line above.
    echo "==> restored user DB from ${BACKUP_DIR}"
}
trap cleanup EXIT

mkdir -p "$DB_DIR"

seed_en() {
    sqlite3 "$DB_PATH" <<SQL
DELETE FROM day_notes WHERE note_date BETWEEN date('now', '-6 days') AND date('now', '+1 days');
INSERT INTO day_notes (note_date, body_md, updated_at) VALUES
  (date('now', '-5 days'), '## Monday kickoff
- [x] Sprint planning
- [x] Portfolio review
- [ ] Schedule standup
### Notes
Moderate energy', datetime('now')),
  (date('now', '-4 days'), '## Tuesday
- [x] Code review (3 PRs)
- [x] Bug fix PR
- [x] Deploy rehearsal
- [ ] Update docs', datetime('now')),
  (date('now', '-3 days'), '## Wednesday
- [ ] Read research paper
- [x] Afternoon walk', datetime('now')),
  (date('now', '-2 days'), '## Thursday
- [x] Move apartment boxes
- [x] Tax paperwork
- [x] Family dinner
- [ ] Prep for next week
### Notes
Heaviest day of the week.', datetime('now')),
  (date('now', '-1 day'), '', datetime('now')),
  (date('now'),          '## Today
- [x] Design review follow-up
- [ ] Clean up README
- [ ] Verify icon
- [x] Lunch appointment', datetime('now')),
  (date('now', '+1 day'), '## Sunday
- Rest day', datetime('now'));
SQL
}

seed_ko() {
    sqlite3 "$DB_PATH" <<SQL
DELETE FROM day_notes WHERE note_date BETWEEN date('now', '-6 days') AND date('now', '+1 days');
INSERT INTO day_notes (note_date, body_md, updated_at) VALUES
  (date('now', '-5 days'), '## 월요일 킥오프
- [x] 스프린트 계획 회의
- [x] 포트폴리오 점검
- [ ] 다음 주 미팅 셋업
### 메모
에너지 보통', datetime('now')),
  (date('now', '-4 days'), '## 화요일
- [x] 코드 리뷰 3건
- [x] 버그 수정 PR
- [x] 배포 리허설
- [ ] 문서 업데이트', datetime('now')),
  (date('now', '-3 days'), '## 수요일
- [ ] 리서치 읽기
- [x] 오후 산책', datetime('now')),
  (date('now', '-2 days'), '## 목요일
- [x] 이사 정리
- [x] 세금 자료
- [x] 가족 저녁
- [ ] 다음주 준비
### 메모
가장 빡셌던 날.', datetime('now')),
  (date('now', '-1 day'), '', datetime('now')),
  (date('now'),          '## 오늘 할 일
- [x] 디자인 리뷰 반영
- [ ] README 정리
- [ ] 아이콘 확인
- [x] 점심 약속', datetime('now')),
  (date('now', '+1 day'), '## 일요일
- 쉬는 날', datetime('now'));
SQL
}

press_button() {
    local index="$1"
    osascript <<EOF
tell application "System Events" to tell process "DayflowApp"
  set btns to every button of group 1 of window 1
  perform action "AXPress" of (item $index of btns)
end tell
EOF
}

capture_full_window_to() {
    local out_file="$1"
    local raw="/tmp/dayflow-capture-raw.png"
    screencapture -x "$raw"
    python3 - "$raw" "$out_file" <<'PY'
import sys
from PIL import Image
raw, out = sys.argv[1], sys.argv[2]
img = Image.open(raw)
cropped = img.crop((160, 160, 160 + 2880, 160 + 1840))
cropped = cropped.resize((1440, 920), Image.LANCZOS)
cropped.save(out)
PY
    rm -f "$raw"
    echo "  captured: $out_file"
}

capture_settings_window_to() {
    local out_file="$1"
    local raw="/tmp/dayflow-capture-settings.png"
    screencapture -x "$raw"
    python3 - "$raw" "$out_file" <<'PY'
import sys
from PIL import Image
raw, out = sys.argv[1], sys.argv[2]
img = Image.open(raw)
# Settings window placed at (500, 150) logical → (1000, 300) retina.
# Crop generously so the System Prompt editor and the buttons underneath
# all make it into the frame.
crop = img.crop((960, 280, 2120, 1900))
target_w = 960
target_h = int(crop.size[1] * target_w / crop.size[0])
crop = crop.resize((target_w, target_h), Image.LANCZOS)
crop.save(out)
PY
    rm -f "$raw"
    echo "  captured: $out_file"
}

capture_for_language() {
    local lang="$1"
    local out_dir="${OUT_ROOT}/${lang}"
    mkdir -p "$out_dir"

    echo "==> capturing ${lang}"

    # Fully quit any running instance so the new `-AppleLanguages` arg
    # actually takes effect AND so we can safely rewrite the DB on disk
    # before the app next opens it (SQLite WAL locks the files).
    osascript -e 'tell application id "com.swryu.dayflow" to quit' 2>/dev/null || true
    sleep 3

    # Seed demo data matching the target language so the Day / Week /
    # Month previews show something meaningful and in-language. The
    # script-level trap restores the user's real DB on exit.
    case "$lang" in
        en) seed_en ;;
        ko) seed_ko ;;
    esac

    # Override the app's AppleLanguages preference BEFORE launch. Command-
    # line `-AppleLanguages '("ko")'` works in theory but bash quoting
    # makes it brittle; `defaults write` is deterministic.
    defaults write "$BUNDLE_ID" AppleLanguages -array "$lang"

    open -n "$APP_PATH"
    sleep 5

    # Park the window at a predictable origin/size so the crop math holds.
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

    # Button indices inside `group 1 of window 1`:
    #   1 Day   2 Week   3 Month   4 chevron-left
    #   5 Today   6 chevron-right   7 refresh
    press_button 1
    sleep 0.3
    press_button 5   # Today — pin to the current date
    sleep 2
    capture_full_window_to "${out_dir}/day.png"

    press_button 2
    sleep 2
    capture_full_window_to "${out_dir}/week.png"

    press_button 3
    sleep 2
    capture_full_window_to "${out_dir}/month.png"

    # Settings window — separate window, separate crop region.
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
    capture_settings_window_to "${out_dir}/settings.png"
}

capture_for_language en
capture_for_language ko

# Cleanup so we don't leave the user stuck on a Korean or English override.
osascript -e 'tell application id "com.swryu.dayflow" to quit' 2>/dev/null || true

echo "==> all screenshots refreshed under ${OUT_ROOT}/{en,ko}/"
