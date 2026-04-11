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

wipe_seed_tables() {
    # Scrub any row that `seed_*` might own so EN/KO runs don't
    # contaminate each other with stale content.
    sqlite3 "$DB_PATH" <<'SQL'
DELETE FROM day_notes WHERE note_date BETWEEN date('now', 'localtime', '-10 days') AND date('now', 'localtime', '+10 days');
DELETE FROM month_plans WHERE month_key = strftime('%Y-%m', 'now', 'localtime');
DELETE FROM appointments WHERE start_at BETWEEN date('now', 'localtime', '-10 days') || 'T00:00' AND date('now', 'localtime', '+10 days') || 'T23:59';
SQL
}

seed_en() {
    sqlite3 "$DB_PATH" <<SQL
INSERT INTO day_notes (note_date, body_md, updated_at) VALUES
  (date('now', 'localtime', '-5 days'), '## Work
- [x] Sprint planning
    - [x] Backlog triage
    - [x] Story pointing
- [x] 1:1 with lead
- [ ] Write proposal draft

## Personal
- [x] Gym
- [ ] Pick up dry cleaning', datetime('now')),
  (date('now', 'localtime', '-4 days'), '## Work
- [x] Code review (3 PRs)
- [x] Bug fix PR
    - [x] Reproduce locally
    - [x] Add regression test
- [ ] Update onboarding docs

## Research
- [ ] Skim latest RAG paper', datetime('now')),
  (date('now', 'localtime', '-3 days'), '## Work
- [x] Deploy rehearsal
- [x] Architecture review notes

## Personal
- [x] Afternoon walk', datetime('now')),
  (date('now', 'localtime', '-2 days'), '## Work
- [x] Ship v0.2 to staging
    - [x] Migration dry-run
    - [x] Smoke test dashboard
    - [x] Rollback plan
- [x] Post-mortem write-up
- [ ] Send summary to team

## Personal
- [x] Grocery run
- [x] Family dinner', datetime('now')),
  (date('now', 'localtime', '-1 day'), '## Work
- [x] Design review follow-up
- [ ] Retro notes

## Research
- [ ] Finish reading paper', datetime('now')),
  (date('now', 'localtime'),           '## Work
- [x] Morning inbox zero
- [ ] Finalize Q2 proposal
    - [x] Draft bullets
    - [ ] Pricing table
    - [ ] Review with lead
- [ ] Post release notes

## Personal
- [x] Coffee with Min
- [ ] Run 5k', datetime('now')),
  (date('now', 'localtime', '+1 day'), '## Personal
- [ ] Rest day', datetime('now'));

INSERT INTO month_plans (month_key, body_md, updated_at) VALUES
  (strftime('%Y-%m', 'now', 'localtime'), '## This month
- [x] Ship v0.2
- [ ] Land Q2 proposal
    - [x] Kick-off meeting
    - [ ] Review with lead
    - [ ] Send to customer
- [ ] Read 2 research papers
- [ ] Plan 3-day holiday', datetime('now'));

INSERT INTO appointments (start_at, end_at, title, note, created_at, updated_at) VALUES
  (date('now', 'localtime', '-2 days') || 'T10:00', NULL, 'Architecture review',  NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '-1 day')  || 'T14:30', NULL, 'Design review',        NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T09:30', NULL, 'Standup',              NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T12:30', NULL, 'Lunch · Min',          NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T16:00', NULL, 'Proposal sync',        NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '+1 day')  || 'T10:00', NULL, 'Dentist',              NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '+2 days') || 'T18:00', NULL, 'Team dinner',          NULL, datetime('now'), datetime('now'));
SQL
}

seed_ko() {
    sqlite3 "$DB_PATH" <<SQL
INSERT INTO day_notes (note_date, body_md, updated_at) VALUES
  (date('now', 'localtime', '-5 days'), '## 업무
- [x] 스프린트 계획 회의
    - [x] 백로그 정리
    - [x] 스토리 포인팅
- [x] 팀장 1:1
- [ ] 기획서 초안 쓰기

## 개인
- [x] 헬스
- [ ] 세탁소 찾기', datetime('now')),
  (date('now', 'localtime', '-4 days'), '## 업무
- [x] 코드 리뷰 3건
- [x] 버그 수정 PR
    - [x] 로컬 재현
    - [x] 회귀 테스트 추가
- [ ] 온보딩 문서 업데이트

## 리서치
- [ ] RAG 논문 훑기', datetime('now')),
  (date('now', 'localtime', '-3 days'), '## 업무
- [x] 배포 리허설
- [x] 아키텍처 리뷰 노트

## 개인
- [x] 오후 산책', datetime('now')),
  (date('now', 'localtime', '-2 days'), '## 업무
- [x] v0.2 스테이징 배포
    - [x] 마이그레이션 드라이런
    - [x] 스모크 테스트 대시보드
    - [x] 롤백 플랜
- [x] 포스트모템 정리
- [ ] 팀 요약 발송

## 개인
- [x] 장보기
- [x] 가족 저녁', datetime('now')),
  (date('now', 'localtime', '-1 day'), '## 업무
- [x] 디자인 리뷰 반영
- [ ] 회고 노트

## 리서치
- [ ] 논문 마무리', datetime('now')),
  (date('now', 'localtime'),           '## 업무
- [x] 아침 메일 정리
- [ ] Q2 제안서 마무리
    - [x] 불릿 초안
    - [ ] 가격표
    - [ ] 팀장 검토
- [ ] 릴리즈 노트 발행

## 개인
- [x] 민이랑 커피
- [ ] 5km 달리기', datetime('now')),
  (date('now', 'localtime', '+1 day'), '## 개인
- [ ] 쉬는 날', datetime('now'));

INSERT INTO month_plans (month_key, body_md, updated_at) VALUES
  (strftime('%Y-%m', 'now', 'localtime'), '## 이달 목표
- [x] v0.2 배포
- [ ] Q2 제안서 확정
    - [x] 킥오프 회의
    - [ ] 팀장 검토
    - [ ] 고객사 전달
- [ ] 리서치 논문 2편 읽기
- [ ] 3일 휴가 계획', datetime('now'));

INSERT INTO appointments (start_at, end_at, title, note, created_at, updated_at) VALUES
  (date('now', 'localtime', '-2 days') || 'T10:00', NULL, '아키텍처 리뷰',  NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '-1 day')  || 'T14:30', NULL, '디자인 리뷰',    NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T09:30', NULL, '스탠드업',       NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T12:30', NULL, '점심 · 민',      NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime')            || 'T16:00', NULL, '제안서 싱크',    NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '+1 day')  || 'T10:00', NULL, '치과',           NULL, datetime('now'), datetime('now')),
  (date('now', 'localtime', '+2 days') || 'T18:00', NULL, '팀 저녁',        NULL, datetime('now'), datetime('now'));
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

    # Scrub previous seed rows first so EN and KO runs don't
    # contaminate each other, then seed fresh in-language data. The
    # script-level trap restores the user's real DB on exit.
    wipe_seed_tables
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
