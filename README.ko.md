# Dayflow

> 🇺🇸 [English README](README.md)

macOS 네이티브 개인 캘린더. 하루 단위 작업 정리와 진행률 추적을 위한 경량 앱. 단일 사용자 / 로컬 우선 / 의도적으로 작게 설계.

## 개요

Dayflow 는 하루를 순수 마크다운(체크리스트, 메모, 중첩 목록) 으로 기록하고 주간·월간 단위로 리듬을 되짚어볼 수 있게 해주는 앱이다. 메뉴바에 상주하고, 전역 단축키에 반응하며, 원하면 LLM 에게 오늘 하루 회고를 부탁할 수 있다.

모든 건 네 컴퓨터 안에서만 돌아간다. 동기화 없음. 회고 패널의 **Generate** 버튼을 명시적으로 누르지 않는 한 아무것도 외부로 나가지 않는다.

## 화면

### Day 뷰
왼쪽은 마크다운 에디터, 오른쪽은 오늘 완료율. 체크리스트, 메모, 중첩 목록이 하루 하나의 본문 안에 모두 들어간다.

![Day 뷰](Dayflow-macOS/docs/screenshots/day.png)

### Week 뷰
7개 컬럼, 하루씩. 각 컬럼은 그 날의 헤딩과 task 를 짧게 프리뷰로 보여준다. 체크박스는 현장 토글 — 박스를 눌러도 Week 뷰에서 벗어나지 않는다.

![Week 뷰](Dayflow-macOS/docs/screenshots/week.png)

### Month 뷰
하루마다 활동량에 따라 색이 진해지는 히트맵. 월간 메트릭(완료 건수, 최장 연속 기록, 가장 활발했던 요일) 과 가장 바빴던 날에서 뽑아낸 "이번 달의 한 줄" 함께 표시.

![Month 뷰](Dayflow-macOS/docs/screenshots/month.png)

### Settings
제공자(OpenAI 또는 Anthropic) 선택, 키 붙여넣기, 모델 선택, 일일 회고에 사용할 시스템 프롬프트 편집까지. 각 필드 독립 편집 가능하고 모든 값은 로컬에만 머문다.

![Settings](Dayflow-macOS/docs/screenshots/settings.png)

## 주요 기능

**Day / Week / Month 3개 뷰**
- **Day** — 블록 기반 WYSIWYG 마크다운 에디터, 오늘 완료율, LLM 회고 패널
- **Week** — 7일 컬럼 그리드, 각 날 프리뷰. 각 컬럼 안 체크박스를 눌러서 Week 를 떠나지 않고 바로 토글
- **Month** — 히트맵, 월간 메트릭, 가장 활발했던 날에서 뽑은 "이번 달의 한 줄"

**마크다운 에디터 (BlockNote 기반)**
- 입력 즉시 렌더링: `#`, `##`, `###`, `-`, `- [ ]`, `- [x]`, `1.`
- 한국어 IME 정상 지원
- `Tab` / `Shift+Tab` 으로 들여쓰기, 불릿과 체크리스트 교차 중첩 자유

**Quick Throw**
- 전역 단축키 `Cmd+Shift+I` — 어떤 앱에서든 작은 입력 패널 팝업
- 한 줄 제목 + 날짜 피커. 선택한 날의 노트에 항목이 append 돼서 과거/미래 날짜로 자유롭게 예약 가능
- 현재 보이는 뷰는 in-place 로 갱신됨 (전체 새로고침 없이)

**메뉴바 상주**
- 메뉴바 텍스트가 현재 미완료 task 개수 ("N open") 또는 전부 완료 시 "all done" 을 실시간 반영
- 클릭하면 축약된 Day 뷰 팝오버

**LLM 일일 회고 (선택)**
- 특정 날짜를 한 방에 요약: *잘한 것 / 막힌 것 / 내일 우선순위 3가지*
- OpenAI, Anthropic 지원
- 제공자, 키, 모델, 시스템 프롬프트 전부 Settings 창에서 직접 설정
- 저장 전에 **연결 테스트** 버튼으로 실제 요청 한 번 쏴서 자격증명 사전 검증 가능
- API 키는 macOS **Keychain** 에 저장. `.env` 파일이나 터미널 조작 없음

**자동 실행 (선택)**
- LaunchAgent plist 포함 — 원하면 로그인 시 자동 기동 설정 가능

## 요구 사항

- macOS 14.0 이상
- Xcode Command Line Tools (처음 빌드 시)

## 설치

```bash
cd Dayflow-macOS
./build.sh
```

`build.sh` 가 릴리즈 빌드 → `.app` 번들 구성 → 현재 버전/빌드 번호로 `Info.plist` 작성 → ad-hoc 코드사인 → `/Applications/Dayflow.app` 설치까지 한 번에 처리한다. 완료되면 Launchpad 나 Spotlight 에서 Dayflow 실행 가능.

### 로그인 시 자동 기동 (선택)

```bash
cp Dayflow-macOS/com.swryu.Dayflow.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.swryu.Dayflow.plist
```

해제:

```bash
launchctl unload ~/Library/LaunchAgents/com.swryu.Dayflow.plist
```

### LLM 제공자 설정 (선택)

일일 회고 기능은 OpenAI 또는 Anthropic 을 호출한다. 둘 다 필수 아님 — 키를 한 번도 등록하지 않아도 나머지 기능은 전부 정상 작동하고, **Generate** 버튼만 "키가 없다" 는 메시지를 표시한다.

**Dayflow → Settings…** (또는 `⌘,`) 을 열고 다음 순서로 입력:

1. **Provider** — OpenAI 또는 Anthropic 중 선택. 제공자마다 독립된 Keychain 슬롯을 쓰므로 전환해도 이전 키가 날아가지 않음.
2. **API Key** — 키 붙여넣기. `SecureField` 라서 값이 다시 표시되지 않음. 이미 저장된 키가 있으면 라벨 아래에 "현재 저장된 키가 있어. 바꾸려면 새 값을 입력해." 힌트가 뜨고, 이 상태에서는 API Key 필드를 비워둔 채 모델 / 시스템 프롬프트만 업데이트해서 저장해도 된다.
3. **Model** — 해당 제공자의 프리셋 드롭다운에서 선택.
4. **System Prompt** — LLM 에게 보내는 지시문을 직접 편집할 수 있는 멀티라인 에디터. 내장 기본값은 한국어로 3섹션(잘한 것 / 막힌 것 / 내일 우선순위) 회고를 요청한다. 톤, 언어, 구조를 자유롭게 바꿔도 되고, 언제든 **기본값으로 복원** 버튼 한 번으로 내장 프롬프트로 돌아갈 수 있다.
5. **연결 테스트** — 선택이지만 권장. 현재 입력으로 실제 요청을 한 번 쏴서 응답 (또는 호출된 URL 이 박힌 전체 에러) 을 인라인으로 보여준다.
6. **저장**

키 발급 링크:

- OpenAI: https://platform.openai.com/api-keys
- Anthropic: https://console.anthropic.com/settings/keys

## 사용법

### 기본 조작
- 앱을 실행하면 오늘 날짜의 Day 뷰로 진입
- 에디터에 그냥 타이핑 — 모든 편집은 debounce 후 자동 저장
- 상단 `Day` / `Week` / `Month` 탭으로 뷰 전환
- 좌우 chevron 으로 단위별(일/주/월) 이동, `Today` 로 오늘 복귀

### 단축키

| 단축키 | 동작 |
|--------|------|
| `Cmd+N` | Quick Throw 패널 열기 |
| `Cmd+R` | 데이터 새로고침 |
| `Cmd+,` | Preferences 창 |
| `Cmd+Shift+I` | 전역 Quick Throw (Dayflow 가 백그라운드여도 동작) |

### 체크리스트

```markdown
- [ ] 미완료 항목
- [x] 완료 항목
```

체크박스 상태는 오른쪽 진행률 패널과 Week / Month 뷰 집계에 즉시 반영된다. Week 뷰에서는 컬럼 안 체크박스를 직접 눌러서 Day 뷰로 이동하지 않고 토글할 수 있다.

## 데이터와 개인정보

Dayflow 는 의도적으로 로컬 전용 앱이다.

**저장 위치**
- 노트 / 회고 DB: `~/Library/Application Support/Dayflow/dayflow.db` (SQLite, WAL 모드)
- API 키: macOS **Keychain** (평문 파일이나 환경변수에 쓰지 않음)
- 선택한 Provider / Model / 커스텀 시스템 프롬프트: `UserDefaults` (역시 로컬만)

**외부로 나가는 것**
- 일일 회고 패널에서 **Generate** 버튼을 눌렀을 때만. 네가 선택한 제공자(OpenAI 또는 Anthropic) 로 HTTPS 요청 1건이 나가고, 본문에는 3가지만 포함된다: 날짜 문자열(`yyyy-MM-dd`), 그 날의 원본 마크다운, Settings 에 저장된 현재 시스템 프롬프트
- 그 외에는 아무것도 전송되지 않는다. 다른 날 데이터, 장치 식별자, 텔레메트리, 크래시 리포트 전부 없음

**백업**
`~/Library/Application Support/Dayflow/` 디렉토리 전체를 복사해두면 끝. DB 와 함께 WAL / SHM 파일까지 세트로.

---

개발 / 기여 관련 정보는 [CONTRIBUTING.md](CONTRIBUTING.md) 참조.
