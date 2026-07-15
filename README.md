# agent-meong

`agent-meong`은 실행 중인 AI 에이전트의 활동을 단순한 점의 움직임으로 보여주는
macOS 메뉴 막대 앱이다. 여러 작업을 맡긴 뒤 잠시 쉬면서도 작업이 계속되는지,
마무리되는지를 방해받지 않고 가볍게 확인하는 것을 목표로 한다.

기능과 디자인의 판단 기준은 [Product Principles](docs/product-principles.md)에
정리되어 있다.

## 현재 기능

- 메뉴 막대 아이콘을 클릭하면 아이콘에 붙은 Meong Space를 즉시 표시
- SpriteKit 기반의 점 형태 에이전트 시각화
- Codex session당 메인 1개, `agent_id`당 서브에이전트 1개로 정규화
- active, attention, uncertain, completed, failed 상태 표현
- 실제 논리 작업과 1:1로 대응하는 오브젝트와 결정론적 색상
- 완료 객체의 지연 소멸과 무응답 객체의 uncertain 전환
- 사용자 전용 Unix domain socket을 통한 로컬 이벤트 수신
- Reduce Motion 지원과 닫힌 popover의 렌더링 일시 정지
- 프롬프트, 응답, 명령, 파일 경로를 수집하지 않는 Codex adapter

현재 구현은 Codex lifecycle hook을 지원한다. 다른 에이전트 도구용 adapter와
일반 사용자용 연결 설치 흐름은 아직 포함하지 않는다.

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

## 앱 패키징

개발용 ad-hoc 서명 앱 번들을 만든다.

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

## Codex 개발 연결

저장소의 [`.codex/hooks.json`](.codex/hooks.json)은 Codex lifecycle event를
`adapters/codex_hook.py`로 전달한다. 이 저장소를 Codex에서 열었을 때 hook 정의를
검토하고 신뢰한 뒤 새 task를 시작하면 앱과의 통합을 확인할 수 있다.

이 파일은 개발용 프로젝트 로컬 설정이다. 다른 저장소에서 실행하는 Codex까지
관찰하려면 별도의 사용자용 설치 방식이 필요하며, 현재 범위에는 포함되지 않는다.

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
adapter 테스트, reducer checks, Swift 앱 빌드를 순서대로 실행한다.

## 기여

변경 전 [CONTRIBUTING.md](CONTRIBUTING.md)를 확인한다. Pull request와 main
브랜치의 변경은 macOS GitHub Actions에서 `scripts/check`로 검증한다.

## 라이선스

아직 라이선스를 선택하지 않았다. 저장소가 public이어도 별도 라이선스가 추가되기
전까지 재사용·수정·배포 권한이 자동으로 부여되는 것은 아니다.
