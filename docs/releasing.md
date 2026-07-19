# 로컬 패키징과 릴리스

이 문서는 유지보수자를 위한 앱 번들 검증과 향후 공식 바이너리 릴리스 절차를
정리한다. 일반 사용자는 [README](../README.md)의 `scripts/install-app` 경로를 사용한다.

## 현재 배포 정책

현재 공식 사용자 설치 경로는 GitHub의 소스 설치 스크립트 하나다. 사용자는 README에
안내된 `$HOME/agent-meong`에 checkout한 뒤 `bash scripts/install-app`으로 직접
빌드·설치한다. installer는 기본적으로 사용자 전용
`~/Library/LaunchAgents/dev.ailab.agent-meong.plist`도 구성한다. 최초 설치에서
`AGENT_MEONG_START_AT_LOGIN=0`을 지정하면 항목을 만들지 않으며, 이미 존재하는 항목은
그 option으로 변경하지 않는다.

즉시 실행 가능한 `.app` 또는 `.zip`은 GitHub Release에 첨부하지 않는다. 공식
바이너리 배포는 의도적으로 장기 과제로 미뤘으며 현재 source release의 출시
blocker가 아니다.

`dist/`와 `macos/.build/`는 생성물이므로 커밋하지 않는다. source-only 정책을 바꾸기
전에는 ad-hoc 서명 산출물을 공식 바이너리처럼 게시하지 않는다.

## 앱 아이콘 갱신

대표 이미지와 앱 아이콘은 `docs/images/agent-meong-mark.svg`를 같은 원본으로 사용한다.
SVG를 바꿨다면 macOS에서 다음 명령으로 앱 리소스를 다시 만든 뒤 함께 커밋한다.

```bash
bash scripts/generate-app-icon
```

생성된 `macos/Resources/AgentMeong.icns`가 Finder와 Dock에서 선명하게 보이는지 확인한다.

## 로컬 앱 패키징

개발 및 로컬 검증용 ad-hoc 서명 앱 번들을 만든다.

```bash
bash scripts/package-app
codesign --verify --deep --strict dist/AgentMeong.app
open dist/AgentMeong.app
```

release configuration을 검증하려면 다음과 같이 실행한다.

```bash
CONFIGURATION=release bash scripts/package-app
codesign --verify --deep --strict dist/AgentMeong.app
```

UI 검사 시 demo fixture와 함께 Dock 앱으로 노출할 수 있다.

```bash
AGENT_MEONG_DEMO=1 AGENT_MEONG_DEBUG_DOCK=1 AGENT_MEONG_DEBUG_OPEN=1 \
  dist/AgentMeong.app/Contents/MacOS/AgentMeong
```

기본 실행은 실제 agent event를 기다리는 빈 Meong Space다.
`AGENT_MEONG_DEMO=1`일 때만 합성 fixture를 표시한다.

앱 번들, packaging 또는 연결 동작을 변경했다면 [AGENTS.md](../AGENTS.md)와
[CONTRIBUTING.md](../CONTRIBUTING.md)의 검증 명령도 실행한다.

## 장기 과제: 공식 바이너리 릴리스

사전 빌드 앱을 공식 배포하기로 결정하면 다음 조건을 모두 만족해야 한다.

- Developer ID Application 서명
- Hardened Runtime
- Apple notarization
- notarization ticket stapling

먼저 인증 정보를 Keychain에 저장한다.

```bash
xcrun notarytool store-credentials agent-meong-notary
```

그다음 인증서 이름과 Keychain profile을 지정해 릴리스한다. 비밀번호나 API key를
스크립트, shell history 또는 저장소에 저장하지 않는다.

```bash
DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE='agent-meong-notary' \
  bash scripts/release-app
```

성공하면 stapled 앱과 `dist/AgentMeong-<version>.zip`이 생성된다. 배포 전 생성된
앱과 archive를 별도 clean Mac에서 다시 확인한다.

절차는 Apple의 [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)와
[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)을 따른다.
