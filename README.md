# agent-meong

한국어 | [English](README.en.md)

> 이제 '불멍'보단 '에이전트멍'

`agent-meong`은 실행 중인 AI 에이전트의 활동을 움직임으로 보여주는 macOS 앱입니다.

여러 작업을 맡긴 뒤 잠시 쉬면서도 일이 계속되는지, 하나씩 끝나가는지 멍하니 지켜보세요.

## 무엇을 보게 되나요

세 가지 신호만 알면 됩니다.

- **움직임**: 에이전트가 활동 중입니다.
- **고리**: 사용자의 확인이 필요합니다.
- **바깥으로 번지는 파동**: 한 번의 최상위 agent turn이 끝났습니다. 전체 작업의 성공을 뜻하지는 않습니다.

그 밖의 움직임은 다음 규칙을 따릅니다.

- 작업 중인 메인 에이전트가 있다면 메뉴 막대에서 **통통** 움직입니다.
- 서브 에이전트는 메인에서 태어나고, 종료가 관찰되면 메인으로 돌아가 흡수됩니다.
- 활동과 오브젝트가 줄어드는 모습으로 일이 마무리되는 흐름을 느낄 수 있습니다.

메뉴 막대의 모든 색과 형태는 [색상 읽기](#색상-읽기)에서 확인할 수 있습니다.

agent-meong은 로그나 생산성 대시보드가 아닙니다. 프롬프트, 응답, 명령, 파일 경로,
tool input/output을 저장하거나 앱으로 보내지 않습니다. 작업 내용 대신 최소한의 활동
신호만 보여줍니다.

## 설치

현재는 GitHub 소스 설치만 제공합니다. 다음 환경이 필요합니다.

- macOS 14 이상
- Xcode Command Line Tools, Swift 6, `/usr/bin/python3`
- `/hooks`를 지원하는 최신 로컬 Codex

### 설치 방법

다음 내용을 Codex 같은 AI 에이전트에 붙여넣으세요.

```text
아래 README를 읽고 이 Mac에 agent-meong을 설치해 줘.
설치와 연결에 필요한 작업을 진행하되, Codex hook 신뢰 단계에서는
내가 직접 검토할 수 있도록 멈춰서 안내해 줘.
https://raw.githubusercontent.com/dkstm95/agent-meong/refs/heads/main/README.md
```

## Codex 연결

1. 메뉴 막대에 열린 agent-meong에서 `연결 시작`을 누릅니다.
2. 새 Terminal의 Codex에서 `Hooks need review`가 나오면 `Review hooks`를 선택합니다.
3. `User config`에서 다음 7개 lifecycle event가 같은 agent-meong command를 가리키는지
   확인하고 신뢰합니다.

   ```text
   UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
   Stop, SubagentStart, SubagentStop
   ```

4. 앱이 다른 검토 대기 hook이 없다고 확인한 경우에만 `Trust all`을 사용할 수 있습니다.
   다른 항목이 있다면 agent-meong의 7개 event만 신뢰합니다.
5. 메뉴 막대에 `Codex · 활동 대기`가 보이면 연결이 끝난 것입니다.

Codex가 요구하는 hook 신뢰는 사용자가 직접 해야 하는 보안 단계입니다. agent-meong은
이를 대신 쓰거나 우회하지 않습니다. 연결 전에 열어 둔 Codex App·CLI는 완전히 종료한
뒤 다시 여세요.

## 사용하기

- 메뉴 막대 아이콘을 클릭하면 Meong Space가 열립니다.
- 모든 에이전트의 현재 상태는 Meong Space에서 함께 볼 수 있습니다.
- 우상단 `?`를 누르면 움직임과 상태 형태를 다시 확인할 수 있습니다.
- 앱은 `시스템 설정 > 일반 > 로그인 항목`에서 자동 실행을 켜거나 끌 수 있습니다.
- 앱을 다시 열려면 Finder에서 `~/Applications/AgentMeong.app`을 실행합니다.

### 색상 읽기

각 오브젝트의 몸 색과 형태는 해당 에이전트의 현재 상태를 나타냅니다. 메뉴 막대
아이콘은 가장 최근에 바뀐 상태를 보여줍니다. 아이콘의 통통 움직임은 별도 신호이며,
하나 이상의 에이전트가 활동 중이라는 뜻입니다.

| 색 | 상태 | 형태 |
| --- | --- | --- |
| 하늘색 | 고요함 | 점 |
| 청록색 | 활동 중 | 움직임 |
| 주황색 | 확인 필요 | 고리 |
| 회보라색 | 상태 불확실 | 분절 고리 |
| 옅은 파란색 | 종료됨, 결과 미확인 | 열린 호 |
| 보라색 | 완료 | 이중 후광 |
| 회색 | 취소됨 | 가로 막대 |
| 빨간색 | 실패 확인 필요 | 마름모 |

완료, 취소, 실패는 Codex가 결과를 명시한 경우에만 표시합니다. 파란 외곽 파동은 한 번의
최상위 agent turn이 끝났다는 뜻이며 성공 신호가 아닙니다. 색을 구분하기 어려운 경우에도
형태와 VoiceOver로 같은 상태를 알 수 있습니다. Reduce Motion에서는 꺾쇠가 활동 중
움직임을 대신합니다.

## 지원 범위

- 현재는 OpenAI Codex만 지원합니다.
- 이 Mac에서 실행되는 Codex App, ChatGPT 데스크톱 앱 안의 Codex, Codex CLI를 관찰합니다.
- 일반 ChatGPT 대화와 Codex 원격·웹 작업은 표시하지 않습니다.
- 기본 `~/.codex`를 공유하는 Codex App과 CLI는 한 번만 연결하면 됩니다.
- Codex의 `Stop`은 한 번의 agent turn이 끝났다는 뜻입니다. 전체 작업의 성공이나 실패를
  뜻하지 않습니다.
- 미리 빌드한 앱과 자동 업데이트는 아직 제공하지 않습니다.

## 개인정보 보호

Codex hook은 원본 event를 받지만 프롬프트, 응답, 명령, 파일 경로, tool input/output을
저장하거나 전송하지 않습니다. 앱에는 다음 정보만 사용자 전용 로컬 socket으로 보냅니다.

- 원문을 알 수 없도록 변환한 session, turn, agent ID
- lifecycle event와 큰 범주의 tool 종류
- Codex가 명시한 종료 상태

자세한 기준은 [제품 원칙](docs/product-principles.md)과
[observation schema](protocol/event-v0.schema.json)에서 확인할 수 있습니다.

## 업데이트

자동 업데이트는 없습니다. 처음 받은 소스 폴더에서 다음 명령을 실행하세요.

```bash
cd "$HOME/agent-meong"
git pull --ff-only
bash scripts/install-app
```

설치된 연결과 자동 실행 설정은 유지됩니다.

## 연결 해제와 제거

Codex 연결만 끊으려면 Meong Space의 `Codex · …` 상태 버튼에서 `연결 해제`를 누릅니다.
앱과 자동 실행 설정은 그대로 남습니다.

앱, 기본 Codex 연결, 자동 실행 항목과 로컬 데이터를 모두 제거하려면 다음 명령을
실행하세요.

```bash
cd "$HOME/agent-meong"
bash scripts/uninstall-app
```

소스 폴더는 자동으로 삭제하지 않습니다. 제거가 끝난 뒤 필요 없다면 Finder에서
`$HOME/agent-meong`을 휴지통으로 옮기세요.

<details>
<summary>별도 CODEX_HOME을 사용한 경우</summary>

앱을 제거하기 전에 연결한 각 환경에서 hook을 먼저 제거합니다.

```bash
cd "$HOME/agent-meong"
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
```

별도 `CODEX_HOME`에 연결할 때도 같은 환경에서 `bash scripts/install-codex-hook`을
실행합니다. 연결하거나 해제한 뒤에는 해당 Codex를 완전히 종료하고 다시 여세요.

</details>

## 문제 해결

| 보이는 상태 | 확인할 내용 |
| --- | --- |
| 메뉴 막대 아이콘이 없음 | `open "$HOME/Applications/AgentMeong.app"`을 실행하고 메뉴 막대 공간을 확인합니다. |
| Codex에 `/hooks`가 없음 | Codex App·CLI를 최신 버전으로 업데이트합니다. |
| `승인 필요` 또는 `hook 꺼짐` | `Codex 검토 열기`를 누르고 안내된 event를 활성화해 신뢰합니다. |
| `이벤트 대기` | 연결 전에 열어 둔 Codex를 완전히 종료하고 다시 연 뒤 새 로컬 작업을 시작합니다. |
| `복구 필요` | 앱의 복구 버튼을 누르고 필요한 hook을 다시 검토합니다. |
| `destination path ... already exists` | 기존 checkout이면 [업데이트](#업데이트)를 진행합니다. 다른 폴더라면 지우지 말고 이름을 바꿉니다. |

계속 문제가 생기면 [GitHub Issues](https://github.com/dkstm95/agent-meong/issues)에
화면에 표시된 상태와 source revision을 알려주세요. 프롬프트, 응답, 명령, 파일 경로나
tool payload는 첨부하지 마세요.

## 개발과 기여

- [기여 가이드](CONTRIBUTING.md)
- [제품 원칙](docs/product-principles.md)
- 전체 검증: `bash scripts/check`

## 라이선스

[MIT License](LICENSE)
