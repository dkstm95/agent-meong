# agent-meong

`agent-meong`은 실행 중인 AI 에이전트의 활동을 단순한 점의 움직임으로 보여주는
macOS 메뉴 막대 앱이다. 여러 작업을 맡긴 뒤 잠시 쉬면서도 작업이 계속되는지,
마무리되는지를 방해받지 않고 가볍게 확인하는 것을 목표로 한다.

기능과 디자인의 판단 기준은 [Product Principles](docs/product-principles.md)에
정리되어 있다.

## 현재 기능

- 메뉴 막대 아이콘을 클릭하면 아이콘에 붙은 Meong Space를 즉시 표시하고 외부 클릭 시 닫힘
- SpriteKit 기반의 점 형태 에이전트 시각화
- Codex session당 메인 1개, `agent_id`당 서브에이전트 1개로 정규화
- active, attention, uncertain, completed, failed 상태 표현
- 실제 논리 작업과 1:1로 대응하는 오브젝트와 결정론적 색상
- 완료 객체의 지연 소멸과 무응답 객체의 uncertain 전환
- 사용자 전용 Unix domain socket을 통한 로컬 이벤트 수신
- Reduce Motion 지원과 닫힌 popover의 렌더링 일시 정지
- 프롬프트, 응답, 명령, 파일 경로를 수집하지 않는 Codex adapter
- 기존 설정을 보존하는 사용자 범위 Codex hook 설치·복구 흐름

현재 구현은 Codex lifecycle hook을 지원한다. 다른 에이전트 도구용 adapter는 아직
포함하지 않는다.

## 요구 사항

- macOS 14 이상
- Xcode Command Line Tools와 Swift 6
- Python 3 (Codex adapter 및 테스트)

## 개발 실행

전체 검증은 다음 명령으로 실행한다.

```bash
bash scripts/check
```

SwiftPM으로 앱을 직접 실행할 수도 있다.

```bash
cd macos
swift run AgentMeong
```

## 로컬 앱 패키징

개발 및 직접 빌드용 ad-hoc 서명 앱 번들을 만든다. 이 산출물은 로컬 검증용이며
프로젝트의 공식 배포 바이너리가 아니다.

```bash
bash scripts/package-app
open dist/AgentMeong.app
```

UI 검사 시에는 demo fixture와 함께 Dock 앱으로 노출할 수 있다.

```bash
AGENT_MEONG_DEMO=1 AGENT_MEONG_DEBUG_DOCK=1 AGENT_MEONG_DEBUG_OPEN=1 \
  dist/AgentMeong.app/Contents/MacOS/AgentMeong
```

기본 실행은 실제 agent event를 기다리는 빈 Meong Space다.
`AGENT_MEONG_DEMO=1`일 때만 합성 fixture를 표시한다.

## 배포 정책

현재 alpha는 소스 코드만 공개한다. 즉시 실행 가능한 `.app` 또는 `.zip`은 GitHub
Release 등에서 공식 배포하지 않으며, 사용자는 checkout한 소스를 직접 빌드한다.
`dist/`와 `macos/.build/`는 생성물이므로 저장소나 릴리스에 포함하지 않는다.

향후 사전 빌드 앱을 공식 배포하기로 결정하면 Developer ID Application 서명,
Hardened Runtime, Apple notarization과 ticket stapling을 모두 통과해야 한다. 아래
절차는 그 전환을 위한 유지보수자용 경로이며 현재 source-only alpha의 출시 조건은
아니다.

먼저 인증 정보를 Keychain에 저장한다.

```bash
xcrun notarytool store-credentials agent-meong-notary
```

그다음 인증서 이름과 Keychain profile을 지정해 릴리스한다. 비밀번호나 API key를
스크립트 또는 저장소에 저장하지 않는다.

```bash
DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE='agent-meong-notary' \
  bash scripts/release-app
```

성공하면 stapled 앱과 `dist/AgentMeong-<version>.zip`이 생성된다. 절차는 Apple의
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)와
[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)을 따른다.

## Codex 사용자 연결

첫 실행 overlay에서 `Codex 연결 설치`를 누르면 adapter를
`~/Library/Application Support/AgentMeong/`에 복사하고 `~/.codex/hooks.json`의 기존
설정을 보존하면서 agent-meong lifecycle handler만 추가한다. 설치 후 Codex에서
`/hooks`를 열어 표시된 lifecycle event와 command 정의를 검토하고 신뢰한 뒤 새
task를 시작한다. 사용자 범위 hook이므로 다른 저장소의 Codex task에도 적용된다.

소스 checkout에서는 명령으로도 설치하거나 제거할 수 있다.

```bash
bash scripts/install-codex-hook
bash scripts/uninstall-codex-hook
```

손상되거나 예상과 다른 `~/.codex/hooks.json`은 덮어쓰지 않는다. 앱은 설치된 command
정의만 확인하며 Codex의 trust 상태를 직접 확인할 수 없으므로, 첫 event가 오기 전에는
연결 성공으로 표시하지 않는다.

## Codex 개발 연결

저장소의 [`.codex/hooks.json`](.codex/hooks.json)은 Codex lifecycle event를
`adapters/codex_hook.py`로 전달한다. 이 저장소를 Codex에서 열고 `/hooks`를 실행하면
별도의 agent-meong hook 이름이 아니라 lifecycle event와 실행할 command 정의가
표시된다. 해당 정의를 검토하고 신뢰한 뒤 이 저장소에서 새 task를 시작하면 앱과의
통합을 확인할 수 있다.

이 파일은 이 저장소에서 통합을 검증하기 위한 개발용 프로젝트 로컬 설정이며 다른
저장소에는 적용되지 않는다. 일반 사용에는 위의 사용자 범위 설치 흐름을 사용한다.

사용자 범위 hook과 이 개발용 project hook을 동시에 활성화하면 Codex가 둘 다
실행한다. 이 저장소에서 통합을 검증할 때는 `/hooks`에서 둘 중 하나만 활성화한다.

adapter는 프롬프트, 응답, 명령, 파일 경로, tool input/output을 전달하지 않는다.
원본 session, turn, agent 식별자도 SHA-256 기반 opaque identifier로 바꾼다.
다음 metadata만 `/tmp/agent-meong-<uid>.sock`으로 보낸다.

- session, turn, agent의 opaque 논리 식별자
- lifecycle event 종류
- shell, edit, search, browser, other 도구 범주
- terminal outcome

좌상단 chip의 `실행 확인 필요`는 socket 오류가 아니라 아직 유효한 Codex event를
받지 못했다는 뜻이다. 첫 event가 도착하면 안내 overlay를 닫고 마지막 수신 시각을
표시한다.

## 프로젝트 구조

```text
adapters/   Codex event 정규화와 adapter 테스트
macos/      AppKit·SpriteKit 앱과 상태 reducer
protocol/   모델 비종속 observation schema와 fixture
scripts/    로컬 검증과 앱 패키징
docs/       제품 원칙과 장기적인 판단 기준
```

## 검증 방식

현재 Command Line Tools에는 XCTest 모듈이 포함되지 않아 reducer 검증은
`AgentMeongCoreChecks` executable harness가 담당한다. `scripts/check`는 Python
adapter·설치 병합 테스트, reducer checks, Swift 앱 빌드를 순서대로 실행한다.

실제 앱 번들의 hook → socket → UI lifecycle은 다음 명령으로 검증한다.

```bash
bash scripts/check-e2e
```

E2E report는 receiver 준비 여부, popover lifecycle, aggregate state, 논리 actor 수만
허용하며 이 allowlist 밖의 필드가 기록되면 실패한다.

## 기여

변경 전 [CONTRIBUTING.md](CONTRIBUTING.md)를 확인한다. Pull request와 main
브랜치의 변경은 macOS GitHub Actions에서 `scripts/check`로 검증한다.

## 라이선스

[MIT License](LICENSE)로 공개한다.
