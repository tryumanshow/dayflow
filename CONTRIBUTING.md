# Contributing to Dayflow

개발자 대상 문서. 사용자용 정보는 [README.md](README.md) 참조.

## 요구 사항 (개발용)

- macOS 14.0 이상
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 + Pillow — 앱 아이콘 `.icns` 재렌더링에 사용 (`build.sh` 가 있으면 자동 호출)
- `gh` CLI — GitHub 작업용 (선택)

## 빌드

```bash
cd Dayflow-macOS

swift build -c release       # 릴리즈 바이너리만
swift run DayflowApp         # 디버그 실행
./build.sh                   # 빌드 + 번들링 + 서명 + /Applications 설치 전체
```

`build.sh` 는 다음 순서로 동작한다.

1. 버전 결정 — `DAYFLOW_VERSION` 환경변수 → `.release-please-manifest.json` 의 `"."` 필드 → `git describe --tags --abbrev=0` → 마지막 fallback `0.0.0`
2. 빌드 번호 결정 — `git rev-list --count HEAD`
3. `swift build -c release`
4. `Dayflow.app` 번들 구성, 바이너리 복사
5. `python3 tools/make_icon.py` 로 `.icns` 재렌더링 (Pillow 필요, 없으면 스킵)
6. `Info.plist` 템플릿 생성 (버전 / 빌드 번호 주입)
7. ad-hoc 코드사인
8. `/Applications/Dayflow.app` 로 설치

## 프로젝트 구조

```
Dayflow-macOS/
├── Sources/DayflowApp/
│   ├── DayflowApp.swift          앱 엔트리, WindowGroup + MenuBarExtra + Settings scene
│   ├── ContentView.swift         Day / Week / Month 레이아웃
│   ├── DayflowStore.swift        @Observable 중앙 상태, DB ↔ View 다리
│   ├── DayflowDB.swift           SQLite 래퍼 (day_notes, reviews 2개 테이블)
│   ├── MarkdownWebEditor.swift   BlockNote 기반 WKWebView 브릿지
│   ├── QuickThrowWindow.swift    Quick Throw 패널 (NSPanel + SwiftUI)
│   ├── GlobalHotkey.swift        Carbon 기반 전역 단축키
│   ├── LLMClient.swift           LLM 회고 API 클라이언트 (OpenAI / Anthropic)
│   ├── SettingsView.swift        Preferences 창 (provider / 모델 / 키)
│   └── DesignSystem.swift        디자인 토큰 + DayflowLogo 브랜드 마크
├── tools/
│   ├── make_icon.py              앱 아이콘 .icns 렌더러 (Pillow 기반)
│   └── capture_screenshots.sh    Day/Week/Month/Settings 스크린샷 일괄 재생성
├── docs/screenshots/             README 에 쓰이는 Day/Week/Month/Settings 미리보기
├── build.sh                      빌드, 번들링, 서명, /Applications 설치
├── Package.swift                 Swift Package 정의
└── com.swryu.Dayflow.plist       LaunchAgent 정의
```

리포지토리 루트에는 릴리즈 자동화 파일도 함께 관리된다.

```
.release-please-config.json      release-please 설정
.release-please-manifest.json    현재 버전 (자동 갱신)
.github/workflows/release.yml    Conventional Commits → tag + GitHub Release 자동화
```

## 데이터 모델

런타임 저장소는 SQLite 두 테이블 뿐이다.

```sql
CREATE TABLE day_notes (
    note_date  TEXT PRIMARY KEY,    -- yyyy-MM-dd
    body_md    TEXT NOT NULL,       -- 전체 마크다운 본문 (heading/체크리스트/메모 포함)
    updated_at TEXT NOT NULL
);

CREATE TABLE reviews (
    review_date  TEXT PRIMARY KEY,  -- yyyy-MM-dd
    body_md      TEXT NOT NULL,     -- LLM 회고 결과 마크다운
    generated_at TEXT NOT NULL
);
```

`tasks` / `state_history` / `time_log` / `notes` / `month_plans` 등 초기 스키마에 있던 테이블은 전부 사용하지 않는다. 모든 할 일 / 메모 / 중첩 목록은 `day_notes.body_md` 한 컬럼에 마크다운으로 들어가고, 파싱은 `DayflowDB.parseCheckboxes` + `MarkdownLine.parse` 가 담당한다.

DB 경로는 `DayflowDB.defaultPath` 에서 결정되며 기본적으로 `~/Library/Application Support/Dayflow/dayflow.db` 이다.

## LLM 클라이언트

`LLMClient.swift` 가 OpenAI / Anthropic 두 제공자를 한 진입점 (`LLMClient.dailyReview`) 으로 다룬다. 제공자 선택과 자격증명은 `LLMConfigStore` 가 관리한다.

- **Provider 선택 + 모델** → `UserDefaults`
- **API 키** → macOS Keychain (`kSecClassGenericPassword`, service `dayflow.llm`, account 는 provider 의 raw value)
- 레거시 `dayflow.anthropic` Keychain 슬롯과 `ANTHROPIC_API_KEY` 환경변수는 한 번만 자동 마이그레이션 후 잊혀진다
- OpenAI 는 `/v1/chat/completions` OpenAI 스키마, Anthropic 은 `/v1/messages` 전용 스키마로 분기 디스패치
- `LLMClient.testConnection(...)` 이 Settings 의 "연결 테스트" 버튼을 뒷받침한다 — 저장 이전에 실제 ping 한 방 쏴서 4xx/5xx 진단 가능

Settings UI 는 `SettingsView` 에서 SwiftUI `Settings {}` scene 으로 호스팅된다. 네이티브 Preferences 창 (Cmd+,) 으로 열린다.

## 보안

- API 키는 Keychain 에 저장되고 환경변수 / 설정 파일에 평문 노출되지 않는다
- SQLite 파일은 `0o600`, 상위 디렉토리는 `0o700` 퍼미션으로 생성
- `MarkdownWebEditor` 의 `WKWebView` 는 `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src 'none'; ...">` 로 외부 네트워크 차단. LLM 호출은 WKWebView 와 무관한 Swift `URLSession.shared` 경로를 쓰므로 CSP 의 영향을 받지 않는다
- Safari Web Inspector (`isInspectable = true`) 는 `#if DEBUG` 게이트. 릴리즈 빌드에서는 비활성

**알려진 미결 이슈**: `MarkdownWebEditor` HTML 이 `@blocknote/core@0.15.11` + 해당 stylesheet 를 `https://esm.sh` 에서 런타임 로드한다. CSP 로 일차 방어는 들어갔지만, 공급망 수준 방어를 원하면 BlockNote 를 로컬로 vendor 하고 `WKURLSchemeHandler` 로 서브해야 한다. 후속 작업 후보.

## 커밋 규칙 — Conventional Commits

`release-please` 가 커밋 메시지를 읽어서 버전을 자동으로 올린다. 메시지는 반드시 Conventional Commits 규칙을 따른다.

| prefix | 효과 | 예시 |
|---|---|---|
| `feat: ...` | minor bump (0.1.0 → 0.2.0) | `feat: add dark mode toggle` |
| `fix: ...` | patch bump (0.1.0 → 0.1.1) | `fix: parseCheckboxes now handles tabs` |
| `feat!: ...` 또는 `BREAKING CHANGE:` footer | major bump (0.1.0 → 1.0.0) | `feat!: drop macOS 13 support` |
| `chore:`, `docs:`, `refactor:`, `test:`, `ci:`, `style:` | 버전 영향 없음 | `chore: bump swift-package-manager` |

## 브랜치 워크플로우

1. `main` 에서 feature 브랜치 생성 (`git checkout -b feat/add-dark-mode`)
2. Conventional commit 으로 작업 커밋
3. `git push -u origin feat/add-dark-mode`
4. GitHub PR 로 `main` 머지
5. `release` 워크플로우가 "chore(main): release x.y.z" PR 을 자동으로 생성 / 갱신한다. 이 PR 에는 CHANGELOG 와 `.release-please-manifest.json` 업데이트가 포함된다
6. 해당 릴리즈 PR 을 머지하면 tag 생성 → macOS 러너에서 `.app` 빌드 → `Dayflow-x.y.z.zip` 을 GitHub Release 에 자동 업로드

## 코드 스타일

- 코멘트는 "WHY" 만 남긴다. "WHAT" (무슨 코드인지) 은 코드로 자명해야 한다
- 이모지 / 과장 표현 금지, `핵심`, `중요` 같은 수식어 지양
- 한국어 문서는 선언적 마무리 문장 (`여기서 출발했습니다` 류) 금지
- 변경 이력을 문서에 남기지 않는다 (`이전엔 X 였는데 이제 Y`). 현재 상태만 기술
- 새 코드에는 기존 파일에서 본 스타일을 따른다 (네이밍 / 들여쓰기 / 주석 패턴)

## 디버깅

**마크다운 에디터 내부 (WKWebView)**: macOS 13.3 이상에서 `#if DEBUG` 빌드는 `isInspectable = true` 가 걸린다. Safari → Develop 메뉴 → Dayflow → editor 로 Web Inspector 를 붙일 수 있다. 릴리즈 빌드에서는 비활성이므로 디버깅은 반드시 `swift run DayflowApp` 또는 디버그 빌드로.

**SQLite 직접 조회**:

```bash
sqlite3 ~/Library/Application\ Support/Dayflow/dayflow.db \
  "SELECT note_date, substr(body_md, 1, 80) FROM day_notes ORDER BY note_date DESC LIMIT 5;"
```

**WAL 파일이 쌓일 때**: 정상. `PRAGMA journal_mode=WAL;` 로 설정돼 있어서 `dayflow.db-wal` / `dayflow.db-shm` 가 함께 존재한다. 백업 시에는 세 파일 모두 복사.

## README 스크린샷 재생성

UI 가 바뀌면 `docs/screenshots/*.png` 도 같이 갱신해야 한다. 수동 캡처 대신 스크립트 하나로 전체 재생성.

```bash
cd Dayflow-macOS
./build.sh                       # 먼저 최신 빌드를 /Applications/Dayflow.app 에 설치
./tools/capture_screenshots.sh   # Day / Week / Month / Settings 캡처 후 docs/screenshots/ 에 저장
```

Playwright 는 쓸 수 없다. Dayflow 는 웹 앱이 아니고 SwiftUI 네이티브 창이라 Playwright 의 브라우저 드라이버로 제어할 수 없다. 그래서 이 스크립트는 순수 macOS 도구 조합으로 돌아간다:

- `open /Applications/Dayflow.app` — 앱 기동
- `osascript` + System Events AXPress — 네비 바 버튼 (`Day` / `Week` / `Month` / `Today`) 를 accessibility tree 를 통해 클릭
- 창 위치 / 크기 고정 (`{80, 80}` origin, `1440x920`) 으로 크롭 좌표 예측 가능하게
- `screencapture -x` — 전체 스크린 캡처
- Pillow — retina 좌표 기준 크롭 후 1440x920 으로 다운스케일

첫 실행 시 Terminal (또는 사용 중인 쉘) 에 접근성 권한 부여 필요 — System Settings → Privacy & Security → Accessibility.

## 테스트

현재 자동 테스트는 없다. 검증 방법:

1. `swift build -c release` — zero errors, zero warnings 를 목표로
2. `./build.sh` 설치 후 Day / Week / Month 세 뷰가 모두 렌더되는지 수동 확인
3. Week 뷰의 체크박스 in-place 토글 동작 (클릭 시 Day 로 넘어가지 않고 체크만 바뀌는지)
4. Settings 창에서 Provider 전환 시 API 키 슬롯이 올바르게 교체되는지
5. LLM 호출이 되는 제공자 하나로 "Generate" 버튼을 눌러 응답이 오는지

BlockNote 의 markdown 라운드트립은 특히 BlockNote 버전 올릴 때마다 수동 확인 필요 (`- [x] foo` ↔ `*   [x] foo` 변환 패턴).
