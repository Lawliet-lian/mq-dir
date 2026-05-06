# mq-dir

> AI 멀티태스커를 위한 macOS 네이티브 파일 매니저. 프로젝트와 에이전트를 병렬로 굴릴 수 있는 최대 4개의 독립 패인 — 영구 상태, 네이티브 마감, 타협 없음.

[![status](https://img.shields.io/badge/status-alpha-orange)](#상태)
[![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#요구사항)
[![swift](https://img.shields.io/badge/swift-5.10-orange)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

🌐 [mqdir.com](https://mqdir.com) · 📓 [릴리즈](https://github.com/h5nam/mq-dir/releases) · 🛠 [기여하기](CONTRIBUTING.md) · 🌏 [English](README.md)

![mq-dir hero](.github/assets/readme_hero.png)

## 왜 만들었나

요즘 코딩 세션은 절반이 소스, 절반이 부산물입니다 — 생성된 이미지, 녹화된 데모, PDF, QA 스크린샷, 추출된 트랜스크립트, 다운받은 모델, 디자인 스펙. 어느 것도 코드가 사는 곳에 함께 살지 않고, Finder는 그 분량과 에이전트가 병렬로 만들어내는 작업 흐름을 위해 설계된 적이 없습니다.

mq-dir은 최대 4개의 독립 패인을 나란히 띄워줍니다. 프로젝트별 하나, 에이전트별 하나, 부산물 덤프용 하나처럼요. 각 패인은 자신만의 폴더, 정렬, 스크롤 위치, 컬럼 너비를 따로 갖고 — 실행 종료나 강제 종료를 거쳐도 그대로 기억합니다.

## 기능

**현재 동작 (alpha.9)**

- 🟦 **1 / 2H / 2V / 4-패인 레이아웃** — 포커스된 패인으로 라우팅, 패인별 독립 폴더.
- ↹ **패인별 탭** — Safari 스타일 탭 바와 X/+, ⌘T / ⌘W / ⌘⇧T / ⌘1…⌘9 / ⌘⇧[ / ⌘⇧], 드래그로 재정렬, 우클릭 Close Other / Close to Right / Duplicate, 마지막 탭 안전장치 placeholder.
- 🌳 **VS Code 스타일 트리 뷰** — 탭별 토글, 자식 lazy 로드, 폴더 ⌘-클릭 시 같은 패인의 새 탭으로 오픈.
- 👀 **탭별 프리뷰 패인** — 패인 헤더에서 토글 (또는 ⌘⇧P). 이미지/PDF/코드/비디오/오디오/오피스 문서는 Quick Look으로, `.md`는 MarkdownUI로 GFM(테이블, 코드블록, 리스트) 풀 렌더링. 폴더/다중/빈 선택은 커스텀 요약.
- ⭐ **편집 가능한 즐겨찾기 사이드바** — 폴더 드래그로 추가, 우클릭 Remove/Rename, 드래그로 재정렬, ⌘D로 포커스된 패인의 폴더 추가. 진짜 Finder 폴더 아이콘과 stale 경로 스타일링.
- 📁 **프로젝트(워크스페이스)** — (레이아웃 + 패인 탭 + 포커스)의 이름 붙은 스냅샷. + 버튼으로 생성, 클릭으로 전환, 우클릭 Rename / Delete, 드래그로 재정렬. 전환 시 떠나는 프로젝트는 자동 저장.
- 💾 **상태 영구 저장** — 모든 패인 / 탭 / 즐겨찾기 / 프로젝트가 재실행, 강제 종료, 심지어 스키마 업그레이드(레거시 `state.json` 자동 마이그레이션)에서도 살아남습니다.
- 🔎 **패인별 재귀 검색** — 디바운스, 대소문자 무관 substring 매치, 현재 폴더 서브트리 전체 대상. ⌘F.
- 🔄 **앱 내 자동 업데이트** — Sparkle 2가 24시간마다 appcast 폴링, 새 릴리즈 발견 시 사이드바에 "Update Available" 버튼이 등장해 표준 install/relaunch 흐름으로 진행.
- 🔗 **[cmux](https://cmux.com) 연동** — 사이드바에 CMUX 섹션이 생겨 cmux 워크스페이스를 미러링합니다. 행을 클릭하면 작업 디렉토리가 포커스 패인에서 열리고 (⌘-클릭은 새 탭). cmux는 자체 자식 프로세스로만 소켓 접근하도록 잠겨 있으니 둘 중 하나로 설정:
  - **간단:** cmux → Settings → Automation → Socket Control Mode = Allow All.
  - **엄격:** Socket Control Mode = Password로 두고 `launchctl setenv CMUX_SOCKET_PASSWORD <pw>` (GUI 실행 앱에 환경변수가 닿게) 후 mq-dir 재실행.

  cmux가 미설치 상태면 섹션은 자동으로 숨겨집니다.
- 🎨 **macOS 네이티브 룩** — SwiftUI + AppKit, 시스템 테마 토큰, 손으로 다듬은 앱 아이콘.

**다음 예정**

- 3-패인 레이아웃 옵션.
- 스페이스바 플로팅 Quick Look (Finder 스타일).
- 키보드 단축키 커스터마이즈, 설정 UI.

## 상태

**프리릴리즈.** 모든 태그 빌드는 Developer ID 사인 + Apple notarize 처리됩니다. 위에 적힌 동작 범위는 메인테이너의 일상 사용을 견딜 만큼 안정적이지만, ergonomics와 엣지 케이스 쪽엔 거친 부분이 남아 있습니다. 릴리즈별 상세는 [릴리즈 페이지](https://github.com/h5nam/mq-dir/releases) 참고.

## 요구사항

- macOS 14 (Sonoma) 이상
- Apple Silicon 또는 Intel
- 빌드용: Xcode 15+, [Homebrew](https://brew.sh)

## 설치

### 사인된 DMG로 (권장)

[릴리즈](https://github.com/h5nam/mq-dir/releases)에서 최신 `.dmg`를 받아 `mq-dir.app`을 `/Applications`로 드래그합니다. notarize + staple 되어 있어 Gatekeeper가 우클릭 트릭 없이 바로 열어줍니다. 설치 후 Sparkle이 24시간 주기로 (또는 사이드바 "Update Available" 버튼 클릭으로) 자동 업데이트합니다.

### 소스에서 빌드

```bash
git clone https://github.com/h5nam/mq-dir.git
cd mq-dir
Scripts/bootstrap.sh   # XcodeGen과 xcodes CLI 설치
open mq-dir.xcodeproj
```

`bootstrap.sh`가 `project.yml`을 기반으로 `mq-dir.xcodeproj`를 생성합니다 (XcodeGen이 single source of truth — `.xcodeproj`는 커밋하지 않습니다).

**테스트만 돌리려면** (Xcode 없이 Swift 툴체인만 있으면 OK):

```bash
swift test
```

## 프라이버시

**텔레메트리 없음. 크래시 리포팅 없음. 애널리틱스 없음. v1에선 영원히.**

mq-dir은 자동 업데이트 체크 외엔 모든 면에서 로컬 전용입니다. 파일시스템을 읽어 사용자에게 보여주고, 자체 상태는 `~/Library/Application Support/com.mqdir.app/`에 씁니다. 유일한 외부 통신은 Sparkle이 하루 한 번 `https://h5nam.github.io/mq-dir/appcast.xml`을 가져와 새 릴리즈 유무를 확인하는 것뿐, 그 외엔 어디로도 보내지 않습니다.

향후 v1.x에서 옵트인 크래시 리포팅이 제안된다면, 기본 OFF인 설정 토글로, 소스가 명확히 보이는 형태로만 들어갑니다.

## v1 범위 외

클라우드 동기화, 아카이브 미리보기, 파일 편집, 플러그인, iPadOS/iOS 포팅, 영어 외 로컬라이제이션.

## 기여

PR 환영합니다. 기여는 [DCO](https://developercertificate.org/)로 받습니다 — 모든 커밋에 `Signed-off-by:` 라인이 필요합니다. **CLA 없음.** 워크플로는 [`CONTRIBUTING.md`](CONTRIBUTING.md), 취약점 신고는 [`SECURITY.md`](SECURITY.md), 행동 강령은 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)을 참고하세요.

## 릴리즈 (메인테이너 전용)

```bash
Scripts/release.sh 0.1.0-alpha.10
```

이게 전부. 스크립트가 버전 bump → Developer ID로 Release 빌드 → 모든 중첩 바이너리 inside-out 재사인 (Sparkle helper는 사인을 자동 상속하지 않음) → `mq-dir-notary` keychain 프로필로 notarize + staple → DMG 빌드 + EdDSA 사인 → `docs/appcast.xml`에 새 `<item>` 추가 → `Casks/mq-dir.rb` bump → 태그 + push → GitHub Release 생성까지 한 번에 처리합니다.

**최초 1회 셋업** (메인테이너 머신마다):

```bash
Scripts/sparkle-setup.sh
# → Sparkle 바이너리 도구를 받고 macOS keychain에 EdDSA 키페어를
#   생성한 뒤 공개키를 출력. 이 프로젝트는 이미 project.yml의
#   SUPublicEDKey에 박혀 있으니, 키 로테이션이 필요한 경우에만
#   다시 돌리면 됩니다.

xcrun notarytool store-credentials mq-dir-notary \
    --apple-id <your-apple-id> --team-id WKV6T7K33K \
    --password <app-specific-password>

brew install create-dmg
gh auth login
```

추가로 Developer ID 개인키에 codesign 접근 권한을 한 번 부여해야 합니다: Keychain Access → login → My Certificates → `Developer ID Application: …` 펼치기 → 개인키 우클릭 → Get Info → Access Control → **Allow all applications to access this item**. 이게 빠지면 릴리즈할 때마다 inside-out 재사인 도중 Mac 비밀번호 프롬프트가 ~10번 뜹니다.

GitHub Pages는 이미 `main` / `/docs`를 서빙하도록 설정돼 있어 `https://h5nam.github.io/mq-dir/appcast.xml`은 push 후 1분 안에 반영됩니다.

## 라이선스

MIT — [`LICENSE`](LICENSE) 참고.

## 감사

mq-dir의 쿼드-패인 레이아웃은 SoftwareOK / Nenad Hrg가 만든 오랜 Windows 파일 매니저 **[Q-Dir](https://www.q-dir.com/)**에서 영감을 받았습니다 — 멀티 패인 파일 매니징의 근거를 마련해준 작품. mq-dir은 macOS용 Swift로 독립 클린룸 구현 — **Q-Dir과 제휴/추천/소스 파생 관계가 아닙니다.**
