# AI 작업 지침

이 문서는 AI 작업자의 진입점이다. 변경 전 `README.md`,
`docs/product-principles.md`, `CONTRIBUTING.md`를 읽고 현재 제품 범위와
검증 기준을 확인한다.

## 작업 원칙

- 모델이나 특정 agent 내부 구현에 의존하지 않는 observation을 경계로 사용한다.
- 프롬프트, 응답, 명령, 파일 경로, tool input/output을 수집하지 않는다.
- 관찰된 작업 상태와 장식적인 움직임을 코드에서 분리한다.
- reducer와 adapter 동작은 결정론적 fixture 또는 check로 검증한다.
- 생성물인 `macos/.build/`와 `dist/`는 커밋하지 않는다.

## 완료 기준

코드나 동작을 변경한 뒤 다음 명령을 실행한다.

```bash
bash scripts/check
```

popover, socket, 패키징 또는 앱 연결 동작을 변경했다면 GUI session이 있는 macOS에서
추가로 실행한다.

```bash
bash scripts/check-e2e
```

Codex hook 정의, adapter 실행 또는 trust 경계를 변경했다면 Codex CLI가 설치된
macOS에서 실제 CLI 프로세스를 거치는 격리 acceptance도 실행한다.

```bash
bash scripts/check-codex-cli-acceptance
```

앱 번들 또는 패키징을 변경했다면 추가로 실행한다.

```bash
bash scripts/package-app
codesign --verify --deep --strict dist/AgentMeong.app
```

현재 공식 사용자 설치 경로는 GitHub source installer뿐이다. 사전 빌드 앱 미제공은
의도된 현재 범위이며 출시 blocker로 취급하지 않는다. 훗날 공식 바이너리 배포로
전환할 때만 `scripts/release-app`으로 Developer ID 서명, Hardened Runtime,
notarization, stapling을 모두 검증한다.

커밋과 pull request 규칙은 `CONTRIBUTING.md`를 따른다.
