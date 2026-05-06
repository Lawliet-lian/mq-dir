# mq-dir

> 여러 프로젝트와 AI 에이전트를 동시에 굴리는 사람을 위한 macOS 네이티브 파일 매니저. 최대 4개의 독립된 pane이 나란히, 각 pane이 자기 폴더·정렬·스크롤 위치를 따로 들고 있고, 재시작 후에도 그대로 남아 있습니다.

[![status](https://img.shields.io/badge/status-beta-yellow)](#상태)
[![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#요구사항)
[![swift](https://img.shields.io/badge/swift-5.10-orange)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

🌐 [mqdir.com](https://mqdir.com) · 📓 [Releases](https://github.com/h5nam/mq-dir/releases) · 🛠 [Contributing](CONTRIBUTING.md) · 🌏 [English](README.md)

![mq-dir hero](.github/assets/readme_hero.png)

## 왜 만들었나

요즘 작업은 코드 절반, 부산물 절반입니다. 생성한 이미지, 녹화한 데모, PDF, QA 스크린샷, export한 transcript, 받아둔 모델, 디자인 스펙 — 어느 것도 코드 폴더와 같은 자리에 살지 않고, Finder는 이런 분량과 에이전트가 병렬로 쏟아내는 속도를 위해 만들어진 도구가 아닙니다.

mq-dir은 최대 4개의 pane을 나란히 띄워줍니다. 하나는 프로젝트, 하나는 에이전트, 하나는 산출물 dump처럼 쓰면 됩니다. 각 pane은 자기 폴더·정렬·스크롤 위치·컬럼 너비를 따로 들고 있고, 종료나 강제 종료를 거쳐도 그 상태 그대로 다시 떠오릅니다.

## 기능

**현재 동작 (beta.1)**

- 🟦 **1 / 2H / 2V / 4-pane 레이아웃** — 활성 pane으로 라우팅, pane마다 독립 폴더.
- ↹ **Pane별 탭** — Safari 스타일 탭 바, X / +, ⌘T / ⌘W / ⌘⇧T / ⌘1…⌘9 / ⌘⇧[ / ⌘⇧], 드래그로 재정렬, 우클릭에 Close Other / Close to Right / Duplicate, 마지막 탭 안전장치.
- 🌳 **VS Code 스타일 트리 뷰** — 탭별 토글, 자식 lazy 로드, 폴더에 ⌘-클릭하면 같은 pane의 새 탭으로 열림.
- ⌨️ **키보드 네비게이션 + Finder급 우클릭 메뉴** — ↑/↓로 행 이동, Shift로 다중 선택 확장, Return으로 열기. 우클릭 메뉴에는 Open With ▸ (LaunchServices 후보 + Other…), Get Info, Reveal in Finder, Copy / Copy Path, Duplicate, Move to Trash가 들어 있고 다중 선택 시 선택 전체에 적용됩니다.
- 👀 **탭별 미리보기 패널** — pane 헤더에서 토글 (또는 ⌘⇧P). 이미지·PDF·코드·비디오·오디오·오피스 문서는 Quick Look으로, `.md`는 MarkdownUI로 GFM(테이블, 코드 블록, 리스트) 풀 렌더링. 폴더·다중·빈 선택은 별도 요약을 띄웁니다.
- ⭐ **편집 가능한 즐겨찾기 사이드바** — 폴더 드래그로 추가, 우클릭 Remove / Rename, 드래그로 재정렬, ⌘D로 활성 pane의 폴더를 추가. Finder 폴더 아이콘 그대로, 끊긴 경로는 별도 스타일로 표시.
- 📁 **프로젝트(워크스페이스)** — (레이아웃 + pane 탭 + 활성 pane)을 이름 붙인 스냅샷으로 저장. + 버튼으로 만들고, 클릭으로 전환, 우클릭에서 Rename / Delete, 드래그로 재정렬. 전환할 때 떠나는 프로젝트는 자동 저장됩니다.
- 💾 **상태 영구 저장** — 모든 pane / 탭 / 즐겨찾기 / 프로젝트가 재시작·강제 종료, 심지어 스키마 업그레이드(레거시 `state.json` 자동 마이그레이션)까지 거쳐도 그대로 남습니다.
- 🔎 **Pane별 재귀 검색** — debounce, case-insensitive substring 매치, 현재 폴더 서브트리 전체. ⌘F.
- 🔄 **앱 내 자동 업데이트** — Sparkle 2가 24시간마다 appcast를 polling, 새 릴리즈가 있으면 사이드바에 "Update Available" 버튼이 떠서 표준 install / relaunch 흐름이 진행됩니다.
- 🔗 **[cmux](https://cmux.com) 연동** — 사이드바에 CMUX 섹션이 생기고 cmux 워크스페이스를 미러링합니다. 행 클릭 시 작업 디렉토리가 활성 pane에서 열리고 (⌘-클릭은 새 탭). cmux는 자체 자식 프로세스만 socket 접근하도록 잠겨 있어 둘 중 하나로 풀어줘야 합니다:
  - **간단:** cmux → Settings → Automation → Socket Control Mode = Allow All.
  - **엄격:** Socket Control Mode = Password로 두고 `launchctl setenv CMUX_SOCKET_PASSWORD <pw>` (GUI 실행 앱에 환경변수가 닿게) 한 다음 mq-dir 재실행.

  cmux가 설치되어 있지 않으면 섹션은 자동으로 숨겨집니다.
- 🎨 **macOS 네이티브 룩** — SwiftUI + AppKit, 시스템 테마 토큰, 손으로 다듬은 앱 아이콘.

**다음 예정**

- 3-pane 레이아웃 옵션.
- 스페이스바 floating Quick Look (Finder 스타일).
- 키보드 단축키 커스터마이즈, 설정 UI.

## 상태

**Pre-release.** 모든 태그 빌드는 Developer ID로 서명되고 Apple notarization까지 끝낸 상태로 배포됩니다. 위에 적힌 동작 범위는 메인테이너의 일상 사용을 견딜 정도로 안정적이지만, 사용감과 엣지 케이스 쪽엔 거친 부분이 남아 있습니다. 릴리즈별 상세는 [Releases 페이지](https://github.com/h5nam/mq-dir/releases)에서 확인하세요.

## 요구사항

- macOS 14 (Sonoma) 이상
- Apple Silicon 또는 Intel
- 빌드용: Xcode 15+, [Homebrew](https://brew.sh)

## 설치

### 사인된 DMG로 (권장)

[Releases](https://github.com/h5nam/mq-dir/releases)에서 최신 `.dmg`를 받아 `mq-dir.app`을 `/Applications`로 드래그하세요. notarize + staple 처리되어 있어 Gatekeeper가 우클릭 트릭 없이 바로 열어줍니다. 설치 후엔 Sparkle이 24시간 주기로 (또는 사이드바의 "Update Available" 버튼을 눌렀을 때) 자동 업데이트합니다.

### 소스에서 빌드

```bash
git clone https://github.com/h5nam/mq-dir.git
cd mq-dir
Scripts/bootstrap.sh   # XcodeGen과 xcodes CLI 설치
open mq-dir.xcodeproj
```

`bootstrap.sh`가 `project.yml`을 source of truth로 삼아 `mq-dir.xcodeproj`를 생성합니다 — `.xcodeproj`는 repo에 커밋하지 않습니다.

**테스트만 돌려보고 싶다면** (Xcode 없이 Swift 툴체인만 있어도 됩니다):

```bash
swift test
```

## 프라이버시

**Telemetry 없음. Crash report 없음. Analytics 없음. v1에서는 영원히.**

mq-dir은 자동 업데이트 체크를 빼면 모든 게 로컬에서 돌아갑니다. 파일 시스템을 읽어서 화면에 보여주고, 자체 상태는 `~/Library/Application Support/com.mqdir.app/`에 씁니다. 외부로 나가는 트래픽은 Sparkle이 하루 한 번 `https://h5nam.github.io/mq-dir/appcast.xml`을 받아오는 것뿐, 그 외엔 어디로도 보내지 않습니다.

향후 v1.x에서 opt-in crash reporting이 제안된다면, 기본값 OFF인 설정 토글로, 소스가 공개되어 검증 가능한 형태로만 들어갑니다.

## v1에서 다루지 않는 것

클라우드 동기화, 아카이브 미리보기, 파일 편집, 플러그인, iPadOS / iOS 포팅, 영어 외 로컬라이제이션.

## 기여

PR 환영합니다. 기여는 [DCO](https://developercertificate.org/) 방식으로 받습니다 — 모든 커밋에 `Signed-off-by:` 줄이 있어야 합니다. **CLA 없음.** 워크플로는 [`CONTRIBUTING.md`](CONTRIBUTING.md), 보안 취약점 신고는 [`SECURITY.md`](SECURITY.md), 행동 규범은 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)을 참고하세요.

## 릴리즈 (메인테이너 전용)

```bash
Scripts/release.sh 0.1.0-alpha.10
```

이게 전부입니다. 스크립트가 버전 bump → Developer ID로 Release 빌드 → 모든 nested binary inside-out 재서명 (Sparkle helper들은 서명을 자동 상속하지 않음) → `mq-dir-notary` keychain profile로 notarize + staple → DMG 빌드 + EdDSA 서명 → `docs/appcast.xml`에 새 `<item>` 추가 → `Casks/mq-dir.rb` bump → 태그 + push → GitHub Release 생성까지 한 번에 처리합니다.

**최초 1회 셋업** (메인테이너 머신마다):

```bash
Scripts/sparkle-setup.sh
# → Sparkle 바이너리 도구를 받고 macOS keychain에 EdDSA 키 페어를
#   생성한 뒤 공개키를 출력. 이 프로젝트는 이미 project.yml의
#   SUPublicEDKey에 박혀 있으니, 키 로테이션이 필요한 경우에만
#   다시 돌리면 됩니다.

xcrun notarytool store-credentials mq-dir-notary \
    --apple-id <your-apple-id> --team-id WKV6T7K33K \
    --password <app-specific-password>

brew install create-dmg
gh auth login
```

여기에 더해 Developer ID 개인키에 codesign 접근 권한을 한 번 부여해야 합니다: Keychain Access → login → My Certificates → `Developer ID Application: …` 펼치기 → 개인키 우클릭 → Get Info → Access Control → **Allow all applications to access this item**. 이걸 안 해두면 릴리즈마다 inside-out 재서명 도중 Mac 비밀번호 프롬프트가 ~10번 뜹니다.

GitHub Pages는 이미 `main` / `/docs`를 서빙하도록 설정되어 있어 `https://h5nam.github.io/mq-dir/appcast.xml`은 push 후 1분 안에 반영됩니다.

## 라이선스

MIT — [`LICENSE`](LICENSE) 참고.

## Inspired by

mq-dir의 4-pane 레이아웃은 SoftwareOK / Nenad Hrg가 만든 Windows의 오랜 파일 매니저 **[Q-Dir](https://www.q-dir.com/)**에서 영감을 받았습니다 — 멀티-pane 파일 매니징의 효용을 입증한 작품입니다. mq-dir은 macOS용으로 Swift에서 처음부터 독립적으로 구현한 것이고, **Q-Dir의 소스를 사용하거나 Q-Dir과 제휴 관계에 있지 않습니다.**
