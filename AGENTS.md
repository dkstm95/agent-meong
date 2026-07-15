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

앱 번들 또는 패키징을 변경했다면 추가로 실행한다.

```bash
bash scripts/package-app
codesign --verify --deep --strict dist/AgentMeong.app
```

현재 source-only alpha에는 사전 빌드 앱을 배포하지 않는다. 향후 공식 바이너리
배포로 전환할 때만 `scripts/release-app`으로 Developer ID 서명, Hardened Runtime,
notarization, stapling을 모두 검증한다.

커밋과 pull request 규칙은 `CONTRIBUTING.md`를 따른다.
