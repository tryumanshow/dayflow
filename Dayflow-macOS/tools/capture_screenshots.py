#!/usr/bin/env python3
"""Capture the README screenshots, once per UI language.

Runs /Applications/Dayflow.app against a throwaway home folder
(`CFFIXED_USER_HOME`), seeds demo notes there, and screenshots each window by
its window id. The user's own database is never opened, copied or
overwritten — the app resolves Application Support under the fake home.

    ./build.sh                           # install the current build first
    python3 tools/capture_screenshots.py

Needs `cliclick` (brew install cliclick) with Accessibility permission for the
terminal, and Pillow. A running Dayflow is quit for the capture (so clicks
can't land in it) and relaunched afterwards; the clipboard's plain text is
restored at the end.
"""
import datetime as dt
import os
import pathlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = pathlib.Path("/Applications/Dayflow.app")
BINARY = APP / "Contents/MacOS/DayflowApp"
BUNDLE_ID = "com.swryu.dayflow"
OUT = ROOT / "docs/screenshots"
WIDTH = 1440  # published width; captures are 2x and scaled down

WINDOW_LIST_SWIFT = r"""
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int32) == pid && (w["kCGWindowLayer"] as? Int) == 0 {
    let b = w["kCGWindowBounds"] as! [String: Any]
    print(w["kCGWindowNumber"]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
"""

# Key codes (layout- and input-method-independent).
KEY_F, KEY_V, KEY_COMMA, KEY_ESC = 3, 9, 43, 53
KEY_1, KEY_2, KEY_3 = 18, 19, 20  # ⌘1/⌘2/⌘3: Day / Week / Month


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def key(code, *mods):
    using = f" using {{{', '.join(m + ' down' for m in mods)}}}" if mods else ""
    subprocess.run(["osascript", "-e", f'tell application "System Events" to key code {code}{using}'], check=True)


def windows(pid):
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(WINDOW_LIST_SWIFT)
    try:
        rows = run("swift", f.name, str(pid)).split("\n")
    finally:
        os.unlink(f.name)
    out = []
    for row in filter(None, rows):
        wid, x, y, w, h = row.split()
        out.append((int(wid), float(x), float(y), float(w), float(h)))
    return out


def main_window(pid):
    for _ in range(40):
        big = [w for w in windows(pid) if w[3] > 600]
        if big:
            return big[0]
        time.sleep(0.5)
    sys.exit("Dayflow window never appeared")


def capture(wid, path):
    raw = path.with_suffix(".raw.png")
    run("screencapture", "-x", "-o", f"-l{wid}", str(raw))
    img = Image.open(raw)
    if img.width > WIDTH:
        img = img.resize((WIDTH, round(img.height * WIDTH / img.width)), Image.LANCZOS)
    img.save(path)
    raw.unlink()
    print("  captured", path.relative_to(ROOT))


def click(x, y):
    run("cliclick", f"c:{int(x)},{int(y)}")


# ---------------------------------------------------------------- demo data

def seed(db_path, lang):
    today = dt.date.today()
    d = lambda n: (today + dt.timedelta(days=n)).isoformat()
    t = (lambda en, ko: ko) if lang == "ko" else (lambda en, ko: en)
    notes = {
        -4: t("## Work\n- [x] Code review (3 PRs)\n- [x] Bug fix PR\n    - [x] Reproduce locally\n    - [x] Add regression test\n- [ ] Update onboarding docs\n\n## Research\n- [ ] Skim the latest RAG paper",
              "## 업무\n- [x] 코드 리뷰 3건\n- [x] 버그 수정 PR\n    - [x] 로컬 재현\n    - [x] 회귀 테스트 추가\n- [ ] 온보딩 문서 업데이트\n\n## 리서치\n- [ ] RAG 논문 훑기"),
        -3: t("## Work\n- [x] Deploy rehearsal\n- [x] Architecture review notes\n\n## Personal\n- [x] Afternoon walk",
              "## 업무\n- [x] 배포 리허설\n- [x] 아키텍처 리뷰 노트\n\n## 개인\n- [x] 오후 산책"),
        -2: t("## Work\n- [x] Ship v0.2 to staging\n    - [x] Migration dry-run\n    - [x] Rollback plan\n- [x] Post-mortem write-up\n- [ ] Send summary to team\n\n## Personal\n- [x] Grocery run",
              "## 업무\n- [x] v0.2 스테이징 배포\n    - [x] 마이그레이션 드라이런\n    - [x] 롤백 플랜\n- [x] 포스트모템 정리\n- [ ] 팀 요약 발송\n\n## 개인\n- [x] 장보기"),
        -1: t("## Work\n- [x] Design review follow-up\n- [ ] Retro notes\n\n## Personal\n- [~] Book flights (waiting on dates)",
              "## 업무\n- [x] 디자인 리뷰 반영\n- [ ] 회고 노트\n\n## 개인\n- [~] 항공권 예약 (날짜 확정 대기)"),
        0: t("## Work\n- [x] Morning inbox zero\n- [ ] Finalize Q2 proposal\n    - [x] Draft bullets\n    - [ ] Pricing table\n    - [ ] Review with lead\n- [ ] Post release notes\n\n## Research\n- [x] Read: Self-Evolving Agents\n- [ ] Notes on eval harness\n\n```python\ndef score(run):\n    return sum(r.passed for r in run) / len(run)\n```\n\n## Personal\n- [x] Coffee with Min\n- [ ] Run 5k",
             "## 업무\n- [x] 아침 메일 정리\n- [ ] Q2 제안서 마무리\n    - [x] 불릿 초안\n    - [ ] 가격표\n    - [ ] 팀장 검토\n- [ ] 릴리즈 노트 발행\n\n## 리서치\n- [x] Self-Evolving Agents 읽기\n- [ ] 평가 하네스 노트\n\n```python\ndef score(run):\n    return sum(r.passed for r in run) / len(run)\n```\n\n## 개인\n- [x] 민이랑 커피\n- [ ] 5km 달리기"),
        1: t("## Personal\n- [ ] Rest day", "## 개인\n- [ ] 쉬는 날"),
    }
    plan = t("## This month\n- [x] Ship v0.2\n- [ ] Land Q2 proposal\n    - [x] Kick-off meeting\n    - [ ] Send to customer\n- [ ] Read 2 research papers",
             "## 이달 목표\n- [x] v0.2 배포\n- [ ] Q2 제안서 확정\n    - [x] 킥오프 회의\n    - [ ] 고객사 전달\n- [ ] 논문 2편 읽기")
    appointments = [  # (day offset, "HH:MM" or None for all-day, end day offset or None, title, category)
        (-2, "10:00", None, t("Architecture review", "아키텍처 리뷰"), "event"),
        (0, "09:30", None, t("Standup", "스탠드업"), "weekly"),
        (0, "12:30", None, t("Lunch · Min", "점심 · 민"), "event"),
        (0, "16:00", None, t("Proposal sync", "제안서 싱크"), "important"),
        (1, None, None, t("Passport renewal", "여권 갱신"), "reminder"),
        (2, None, 4, t("Offsite · Busan", "워크숍 · 부산"), "event"),
        (3, None, 5, t("Conference", "컨퍼런스"), "monthly"),
    ]
    now = dt.datetime.now().isoformat(timespec="seconds")
    con = sqlite3.connect(db_path)
    with con:
        con.executemany("INSERT OR REPLACE INTO day_notes (note_date, body_md, updated_at) VALUES (?, ?, ?)",
                        [(d(n), body, now) for n, body in notes.items()])
        con.execute("INSERT INTO month_plan_sections (month_key, title, sort_order, body_md, updated_at) VALUES (?, ?, 0, ?, ?)",
                    (today.strftime("%Y-%m"), t("Goals", "이달 목표"), plan, now))
        for day, hhmm, end, title, cat in appointments:
            start = d(day) + "T" + (hhmm or "00:00")
            end_at = d(end) + "T23:59" if end is not None else None
            con.execute("INSERT INTO appointments (start_at, end_at, title, note, category, created_at, updated_at, all_day) VALUES (?, ?, ?, NULL, ?, ?, ?, ?)",
                        (start, end_at, title, cat, now, now, 1 if hhmm is None else 0))
    con.close()


# ---------------------------------------------------------------- capture

def front(app):
    run("osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {app.pid}) to true')


def launch(home, lang, theme="midnight"):
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))
    return subprocess.Popen([str(BINARY), "-AppleLanguages", f"({lang})", "-dayflow.theme", theme],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def capture_language(lang):
    out = OUT / lang
    out.mkdir(parents=True, exist_ok=True)
    home = pathlib.Path(tempfile.mkdtemp(prefix=f"dayflow-shots-{lang}-"))
    db = home / "Library/Application Support/Dayflow/dayflow.db"
    print(f"==> {lang} (home {home})")
    try:
        first = launch(home, lang)          # first run creates the schema
        for _ in range(40):
            if db.exists():
                break
            time.sleep(0.25)
        time.sleep(2)
        stop(first)
        seed(db, lang)

        app = launch(home, lang)
        wid, x, y, w, h = main_window(app.pid)
        front(app)
        time.sleep(3)  # editor web view + first render
        capture(wid, out / "day.png")
        key(KEY_2, "command"); time.sleep(1.2); capture(wid, out / "week.png")
        key(KEY_3, "command"); time.sleep(1.2); capture(wid, out / "month.png")
        key(KEY_1, "command"); time.sleep(1.0)

        # Carry-over sheet, from the banner's "Review" button (right end).
        click(x + w - 60, y + 97); time.sleep(1.2)
        sheet = [win for win in windows(app.pid) if win[0] != wid]
        capture(sheet[0][0] if sheet else wid, out / "carryover.png")
        key(KEY_ESC); time.sleep(0.6)

        # Global search: query pasted, so the input method can't mangle it.
        subprocess.run(["pbcopy"], input="PR", text=True, check=True)
        key(KEY_F, "command", "shift"); time.sleep(0.8)
        key(KEY_V, "command"); time.sleep(1.0)
        capture(wid, out / "search.png")
        key(KEY_ESC); time.sleep(0.6)

        front(app)
        key(KEY_COMMA, "command")
        settings = []
        for _ in range(12):
            time.sleep(0.5)
            settings = [win for win in windows(app.pid) if win[0] != wid]
            if settings:
                break
        if settings:
            time.sleep(0.8)
            capture(settings[0][0], out / "settings.png")
        else:
            print("  !! settings window did not open; settings.png left as is")
        stop(app)

        # The light theme, for the README's theme section.
        app = launch(home, lang, theme="paper")
        wid, *_ = main_window(app.pid)
        front(app)
        time.sleep(6)  # the editor web view loads after the window appears
        capture(wid, out / "day-paper.png")
        stop(app)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main():
    if not BINARY.exists():
        sys.exit(f"{APP} missing — run ./build.sh first")
    was_running = subprocess.run(["pgrep", "-f", str(BINARY)], capture_output=True).returncode == 0
    clipboard = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
    if was_running:
        subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'])
        time.sleep(3)
    try:
        for lang in ("en", "ko"):
            capture_language(lang)
    finally:
        subprocess.run(["pbcopy"], input=clipboard, text=True)
        if was_running:
            subprocess.run(["open", str(APP)])


if __name__ == "__main__":
    main()
