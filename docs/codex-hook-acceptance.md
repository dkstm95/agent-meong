# Codex hook 인수 검증

이 체크리스트는 사용자 hook 설치와 Codex의 신뢰 승인을 구분한다. agent-meong은
`hooks.json`과 adapter가 설치되었는지는 확인할 수 있지만, Codex가 현재 command
정의를 신뢰했는지는 직접 확인하거나 대신 승인하지 않는다. 첫 실제 lifecycle event가
도착하기 전에는 앱도 연결 성공으로 표시하지 않아야 한다.

## 격리 자동 검증

다음 명령은 실제 사용자 설정과 다른 임시 `HOME` 및 `CODEX_HOME`에서 실행된다.

```bash
bash scripts/check-codex-hook
```

이 검증은 다음을 확인한다.

- 기존 hook과 최상위 JSON 필드가 설치·복구·해제 뒤에도 보존된다.
- 사용자 hook은 지원하는 lifecycle event마다 정확한 adapter command 하나만 추가한다.
- `CODEX_HOME`을 사용하며 기본 `~/.codex/hooks.json`을 건드리지 않는다.
- adapter 또는 command 정의가 달라지면 연결 완료가 아니라 복구 필요로 판정한다.
- 연결 해제는 agent-meong command와 adapter만 제거한다.
- installer는 Codex trust 상태 파일을 만들거나 신뢰 승인을 완료한 것으로 판정하지 않는다.

이 검증은 Codex를 실행하지 않으므로 실제 신뢰 화면의 대체물이 아니다.

## 깨끗한 사용자 환경 수동 검증

Finder에서 실행한 Codex App은 터미널의 임시 `HOME`을 그대로 사용하는 검증 대상이
아니다. 실제 App과 CLI를 함께 확인할 때는 별도의 일회용 macOS 사용자 계정을 사용한다.

1. 새 계정에서 README의 `scripts/install-app` 경로로 앱을 설치하고, 첫 화면에서
   `Codex 연결하기`를 누른다. 앱은 `사용자 hook 설치됨`과 `신뢰 필요`를 분리해서
   보여야 하며 아직 `연결됨`이라고 표시하면 안 된다.
2. Codex CLI에서 새 task를 열고 `/hooks`를 실행한다. 사용자 source의
   `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`,
   `SubagentStart`, `SubagentStop`, `Stop`과 각 event 아래의 정확한
   `/usr/bin/python3 .../codex_hook.py` command를 검토한 뒤 신뢰한다. 별도의
   `agent-meong` hook 이름이 보일 것을 기대하지 않는다.
3. CLI에서 새 task를 하나 시작한다. 첫 실제 event 뒤 agent-meong 안내가 닫히고
   메뉴바의 점과 Meong Space에 실제 활동이 나타나는지 확인한다.
4. Codex App에서 새 task를 시작해 같은 연결이 동작하는지 확인한다. Codex App이
   별도 검토를 요구하면 동일한 lifecycle event와 command 정의를 검토한다. 앱을
   재실행했을 때는 이전 실제 event 확인 이력만 표시하고, 이번 실행의 event를 이미
   받았다고 주장하지 않아야 한다.
5. agent-meong에서 `연결 해제`를 누른 뒤 `/hooks`를 다시 연다. agent-meong command는
   없어지고 미리 존재하던 다른 hook은 남아 있어야 한다.

[Codex Hooks 문서](https://developers.openai.com/codex/hooks)에 따르면 non-managed
command hook은 현재 정의를 검토하고 신뢰해야 실행되며, 정의가 바뀌면 다시 검토될
때까지 건너뛴다. 따라서 복구나 업데이트 뒤 첫 event가 오지 않으면 `/hooks`에서 현재
정의를 다시 확인하는 것이 올바른 진단이며, agent-meong이 신뢰를 추정해서는 안 된다.
