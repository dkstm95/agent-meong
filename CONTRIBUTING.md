# Contributing to agent-meong

로컬 앱 패키징과 향후 공식 바이너리 배포 절차는
[docs/releasing.md](docs/releasing.md)를 따른다.

## 개발 환경

- macOS 14 이상
- Xcode Command Line Tools와 Swift 6
- Python 3

전체 로컬 검증은 다음 명령 하나로 실행한다.

```bash
bash scripts/check
```

popover, socket, 패키징 또는 앱 연결 동작을 바꿨다면 잠금 해제된 Aqua GUI session이
있는 macOS에서 다음 검증도 실행한다.

```bash
bash scripts/check-e2e
```

Codex hook 정의나 adapter 실행 경로를 바꿨다면 실제 Codex CLI를 격리된 로컬 가짜
모델과 함께 실행하는 다음 acceptance도 통과해야 한다. 사용자 설정과 API key는
사용하지 않으며 모델 트래픽은 localhost 안에서만 발생시킨다.

```bash
bash scripts/check-codex-cli-acceptance
```

## 변경 원칙

- 하나의 커밋에는 하나의 논리적 변경만 담는다.
- 커밋 제목은 가능하면 명령형 55자 이내로 작성한다.
- 사용자에게 보이는 동작이 바뀌면 README도 함께 확인한다.
- reducer 규칙은 `AgentMeongCoreChecks`에, Codex event 변환은 Python adapter
  테스트에 검증을 추가한다.
- 외부 네트워크, API key, 사용자 prompt나 tool payload가 테스트에 필요해서는 안 된다.
- E2E report는 제품의 observation privacy boundary보다 넓은 데이터를 기록하지 않는다.
- `dist/`와 `macos/.build/` 같은 생성물은 커밋하지 않는다.
- 설치, 업데이트, 자동 시작 또는 제거 lifecycle을 바꾸면
  `scripts/check-app-lifecycle` fixture도 함께 갱신한다.
- 현재 공식 사용자 설치 경로는 GitHub source installer뿐이다. 사전 빌드 `.app` 또는
  `.zip` 미제공은 의도된 범위이므로 릴리스 자산으로 첨부하지 않는다.

## Pull request

Pull request에는 다음 내용을 포함한다.

- 변경 목적
- 사용자 또는 구조에 미치는 영향
- 실행한 검증과 결과
- 문서 변경 여부

리뷰에서는 정확성, 개인정보 경계, 상태 lifecycle, 테스트 가능성,
유지보수성을 우선한다.
