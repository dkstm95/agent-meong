# agent-meong

한국어 | [English](README.en.md)

`agent-meong`은 같은 Mac에서 실행 중인 AI 에이전트의 활동을 단순한 점과
올챙이의 움직임으로 보여주는 macOS 메뉴 막대 앱입니다. 여러 작업을 맡긴 뒤 잠시
쉬면서도 일이 계속되는지, 하나씩 끝나가는지를 방해받지 않고 바라보는 경험을
목표로 합니다.

## 무엇을 보게 되나요

- 작업 중인 메인 에이전트는 메뉴 막대에서 통통 움직입니다.
- 메뉴 막대 아이콘을 누르면 아이콘에 붙은 Meong Space가 즉시 열립니다.
- 서브에이전트는 메인에서 태어나고, 종료가 관찰되면 메인으로 돌아가 흡수됩니다.
- 한 번의 최상위 agent turn이 끝나면 푸른 신호와 확인 전까지 남는 ring이 나타납니다.
- 활동과 오브젝트가 줄어드는 모습으로 일이 마무리되는 흐름을 느낄 수 있습니다.

![메뉴 막대 아이콘에 붙어 열린 agent-meong Meong Space](docs/images/agent-meong.png)

이 앱은 상세 로그나 생산성 dashboard가 아닙니다. prompt, response, 명령, 파일 경로,
tool input/output을 수집하지 않으면서 최소한의 실제 lifecycle 신호만 시각화합니다.
기능과 디자인의 판단 기준은 [Product Principles](docs/product-principles.md)에 있습니다.

## 현재 범위와 제약

- macOS 14 이상에서 동작합니다.
- 현재 observation source는 OpenAI Codex 하나입니다.
- **이 Mac에서 로컬로 실행되는** Codex App과 Codex CLI task만 관찰합니다. Codex
  cloud/web task, 다른 Mac, 원격 runner는 관찰하지 않습니다.
- 기본 `~/.codex`를 공유하는 로컬 Codex App과 CLI는 한 번만 연결하면 됩니다.
- Codex App과 CLI의 활동을 모두 관찰할 수 있지만, 최초 command hook 보안 검토와
  신뢰에는 현재 Codex CLI의 `/hooks`가 필요합니다.
- 현재는 source-only alpha입니다. 사전 빌드 앱, 자동 업데이트, 로그인 시 자동 실행은
  제공하지 않습니다.
- Codex가 제공하는 `Stop`은 한 번의 agent turn 종료 신호입니다. 전체 task/thread의
  성공이나 실패를 뜻하지 않으며, Codex가 주지 않는 결과는 추정하지 않습니다.

## 설치 전 확인

다음 항목이 필요합니다.

- Xcode Command Line Tools와 Swift 6
- Command Line Tools가 제공하는 `/usr/bin/python3`
- `/hooks`를 지원하는 최신 Codex CLI
- 관찰할 로컬 Codex App 또는 Codex CLI

Terminal에서 확인합니다.

```bash
xcode-select -p
swift --version
/usr/bin/python3 --version
codex --version
```

`xcode-select -p`가 실패하면 `xcode-select --install`을 실행하세요. Swift가 6.x가
아니거나 Codex CLI에 `/hooks`가 없다면 Xcode Command Line Tools 또는
[Codex CLI](https://developers.openai.com/codex/cli)를 먼저 업데이트하세요.

## 설치

```bash
git clone https://github.com/dkstm95/agent-meong.git
cd agent-meong
bash scripts/install-app
```

스크립트는 release build를 만들고 ad-hoc 서명을 검증한 뒤
`~/Applications/AgentMeong.app`에 설치해 실행합니다. `sudo`는 필요하지 않습니다.
Dock 아이콘은 없으며, 첫 실행에서는 메뉴 막대의 둥근 아이콘에 연결 안내가 자동으로
열립니다. 설치가 성공하면 큰 로컬 build cache인 `dist/`와 `macos/.build/`는 기본적으로
정리됩니다. 자동 업데이트가 없으므로 clone한 폴더는 업데이트와 완전 제거를 위해
보관하세요.

## Codex 연결과 보안 확인

1. agent-meong 첫 화면에서 `Codex 연결하기`를 누릅니다.
2. 앱이 기존 설정을 보존하면서 기본 `~/.codex`에 사용자 hook을 추가하고, adapter를
   `~/Library/Application Support/AgentMeong/codex-hooks/` 아래에 설치합니다.
3. `/hooks 복사`를 누른 뒤 Codex CLI task에 붙여넣습니다.
4. `User config` source 아래의 정의가 다음 체크리스트와 모두 일치할 때만 신뢰합니다.

### `/hooks` 체크리스트

- `agent-meong activity [dev.ailab.agent-meong/v4]` handler가 정확히 다음 7개 event에
  하나씩 있습니다. 기존에 사용자가 설치한 다른 hook은 함께 보일 수 있으며 별도로
  검토해야 합니다.
  - `UserPromptSubmit`
  - `PreToolUse`
  - `PermissionRequest`
  - `PostToolUse`
  - `SubagentStart`
  - `SubagentStop`
  - `Stop`
- 이 7개 agent-meong handler의 type은 모두 `command`입니다.
- 각 agent-meong command는 다음 형태입니다. 사용자 홈과 24자리 16진수 opaque
  directory 값은 Mac마다 다릅니다.

  ```text
  /usr/bin/python3 '/Users/<you>/Library/Application Support/AgentMeong/codex-hooks/<24-hex>/codex_hook.py'
  ```

- `statusMessage`는 정확히
  `agent-meong activity [dev.ailab.agent-meong/v4]`입니다.
- `timeout`은 2초이며 `async` handler가 아닙니다.

하나라도 다르면 신뢰하지 말고 앱과 checkout을 업데이트한 뒤 다시 확인하세요.
별도의 `agent-meong` hook 이름이 보이는 것이 아니라 lifecycle event와 command가
보이는 것이 정상입니다. Codex는 새 정의나 변경된 정의를 신뢰하기 전까지 실행하지
않습니다. 자세한 보안 동작은 [Codex Hooks 공식 문서](https://learn.chatgpt.com/docs/hooks)를
참고하세요.

### 실제 연결 확인

신뢰를 마친 뒤 같은 Mac의 Codex App 또는 CLI에서 **새 local task**를 열고 짧은
prompt를 한 번 보냅니다. cloud task가 아닌지 확인하세요.

연결되면 다음 변화가 나타납니다.

- agent-meong의 연결 안내가 자동으로 닫힙니다.
- 좌상단 chip이 `Codex · 방금`으로 바뀝니다.
- Meong Space에 메인 에이전트 점이 나타나 움직입니다.

hook 파일의 존재만으로 연결 성공을 추정하지 않으며, 첫 실제 event가 도착해야
연결됨으로 표시합니다.

## 일상 사용

- 실행 중인 agent가 있으면 메뉴 막대의 원이 통통 움직입니다.
- 아이콘을 왼쪽 클릭하면 Meong Space가 열리고, 외부를 클릭하면 닫힙니다.
- 여러 local task가 실행 중이면 각 메인·서브에이전트가 별도 오브젝트로 보입니다.
- 최상위 turn 하나가 끝나면 메뉴 막대에 푸른 종료 신호가 나타납니다. 이는 전체
  thread의 성공 판정이 아니라 Codex가 알린 turn 종료입니다.
- 아이콘을 오른쪽 클릭하면 상태, `멍 보기`, `종료` 메뉴가 열립니다.
- 다시 실행하려면 Finder에서 `~/Applications/AgentMeong.app`을 열거나 다음 명령을
  사용합니다.

  ```bash
  open "$HOME/Applications/AgentMeong.app"
  ```

로그인 시 자동 실행은 아직 없으므로 Mac을 재시작한 뒤에는 앱을 다시 열어야 합니다.
현재 source-only ad-hoc build는 업데이트마다 코드 식별자가 달라질 수 있어 안정적인
로그인 항목을 약속하지 않습니다. Reduce Motion과 Increase Contrast 설정을 따릅니다.

## 업데이트

자동 업데이트는 없습니다. 처음 clone한 폴더에서 실행합니다.

```bash
cd /path/to/agent-meong
git pull --ff-only
bash scripts/install-app
```

설치 스크립트는 새 앱을 먼저 빌드·검증한 다음 실행 중인 이전 앱을 종료하고
교체합니다. 교체 중 실패하면 이전 bundle을 복원하고, 원래 실행 중이었다면 다시
엽니다. 재실행 후 `복구 필요`가 보이면 `Codex 연결 복구`를 누르세요. hook 정의가
바뀌었다면 `/hooks`에서 다시 검토·신뢰하고 새 local prompt로 연결을 확인해야 합니다.

## 문제 해결

| 보이는 상태 | 확인할 내용 |
| --- | --- |
| 메뉴 막대 아이콘이 없음 | `open "$HOME/Applications/AgentMeong.app"`을 실행합니다. 계속 실패하면 Terminal의 `bash scripts/install-app` 오류를 확인합니다. |
| Codex에 `/hooks`가 없음 | Codex CLI를 최신 버전으로 업데이트합니다. |
| `확인 필요` 또는 `이벤트 대기` | `/hooks` 신뢰, 같은 Mac의 local task인지, 새 prompt를 보냈는지 확인합니다. |
| `복구 필요` | `Codex 연결 복구`를 눌러 agent-meong 항목만 다시 설치합니다. 기존 다른 hook은 보존됩니다. |
| `hooks 꺼짐` | 현재 Codex 설정의 `[features] hooks = false`를 확인합니다. 관리 정책이 강제한 값이면 관리자에게 문의합니다. |
| `정책 제한` | `requirements.toml` 또는 관리 정책의 `allow_managed_hooks_only = true`가 사용자 hook을 막고 있습니다. 관리자 변경이 필요합니다. |
| `설정 확인` | 현재 Codex home의 `hooks.json` JSON 형식을 고칩니다. agent-meong은 손상된 파일을 덮어쓰지 않습니다. |
| `source 확인` | `config.toml` inline hook과 `hooks.json`이 함께 로드됩니다. `/hooks`에서 모든 source를 검토합니다. |
| `형식 확인` | 앱과 checkout 버전을 맞춘 뒤 `Codex 연결 복구`를 누릅니다. |

해결되지 않으면 [GitHub Issues](https://github.com/dkstm95/agent-meong/issues)에 앱 버전과
표시된 상태를 알려주세요. prompt, response, 명령, 파일 경로 또는 tool payload를
첨부하지 마세요.

## 별도 `CODEX_HOME`

Finder에서 실행한 앱은 shell의 별도 `CODEX_HOME`을 자동으로 알 수 없습니다. 해당
CLI가 쓰는 것과 같은 환경에서 설치하세요.

```bash
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/install-codex-hook
```

그다음 `/hooks` 체크리스트로 신뢰하고 새 local prompt를 보냅니다. 여러 custom home도
각각 같은 방식으로 연결할 수 있습니다. agent-meong은 개인정보 원칙상 실제 custom
home 경로를 저장하지 않으므로, 사용자가 이 경로를 기억해야 합니다.

## Codex 연결 해제

### 기본 `~/.codex`

앱의 연결 chip을 열고 `연결 해제`를 누르는 방법을 권장합니다. agent-meong이 추가한
handler와 adapter만 제거하며, 다른 Codex 설정과 hook은 보존합니다. 성공하면 현재
장면, 연결 기록, 재시작 checkpoint도 함께 비웁니다.

소스 checkout에서 hook만 제거할 수도 있습니다.

```bash
bash scripts/uninstall-codex-hook
```

이 명령은 앱의 화면과 저장된 연결 기록을 직접 비우지 않으므로, 앱을 계속 사용할
때는 앱 안의 `연결 해제`를 사용하세요.

### 별도 `CODEX_HOME`

설치할 때 사용한 경로와 같은 환경에서 제거합니다.

```bash
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
```

그다음 앱의 `연결 기록 지우기`를 눌러 로컬 장면과 확인 기록을 비웁니다. 여러 custom
home을 연결했다면 각각 반복합니다.

## 앱과 데이터 완전 제거

순서가 중요합니다. custom hook을 남긴 채 support directory를 지우면 Codex hook이
없는 adapter 경로를 계속 실행하게 됩니다.

1. 연결한 모든 별도 `CODEX_HOME`에서 먼저 hook을 제거합니다.

   ```bash
   CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
   ```

2. 기본 환경에서 완전 제거 스크립트를 실행합니다.

   ```bash
   bash scripts/uninstall-app
   ```

   shell에 별도 `CODEX_HOME`이 export되어 있어도 이 명령은 안전을 위해 기본
   `~/.codex` 연결을 제거합니다.

이 스크립트는 먼저 기본 hook을 제거합니다. 다른 custom adapter가 남아 있으면 앱과
데이터를 지우기 전에 중단하므로, 안내된 custom home에서 1단계를 마친 뒤 다시
실행하세요. 모든 연결이 해제되면 실행 중인 설치 앱, 앱 번들, checkpoint,
UserDefaults, 기본 socket과 lock을 제거합니다. 예상하지 못한 support data나 안전하지
않은 socket 항목을 보존한 경우에는 성공으로 표시하지 않고, 남은 경로를 안내하며
nonzero로 종료합니다.

이전 alpha가 사용하던 공유 adapter가 발견되면 custom home에서 참조 중인지 자동으로
판단할 수 없어 안전하게 중단합니다. 모든 custom home을 해제했음을 직접 확인한 뒤에만
다음과 같이 명시적으로 제거하세요.

```bash
AGENT_MEONG_REMOVE_LEGACY_ADAPTER=1 bash scripts/uninstall-app
```

source checkout 자체는 자동으로 삭제하지 않습니다. 설치 성공 시 `dist/`와
`macos/.build/`는 기본적으로 정리되며, 기여를 위해
`AGENT_MEONG_KEEP_BUILD_ARTIFACTS=1`로 보존했다면 clone과 함께 직접 삭제하세요.

## 개인정보 보호

Codex hook은 원본 JSON을 받지만 다음 정보는 저장·로그·socket 전송하지 않습니다.

- prompt와 response
- 명령과 파일 경로
- tool input/output

앱에는 다음 파생 metadata만 사용자 전용 Unix socket으로 전달합니다.

- SHA-256 기반 32자리 opaque session, turn, agent ID
- lifecycle event 종류와 shell, edit, search, browser, other 도구 범주
- hook definition version과 실제 경로를 드러내지 않는 opaque instance
- Codex가 명시한 종료 사실

짧은 앱 재시작을 위한 checkpoint에는 active, attention, uncertain 오브젝트의 파생
metadata만 사용자 전용 파일로 저장합니다. 원문 event와 종료·성공·실패·취소 객체는
저장하지 않습니다. observation 경계는 [protocol schema](protocol/event-v0.schema.json)에서
확인할 수 있습니다.

## 개발과 기여

- [기여 가이드](CONTRIBUTING.md)
- [제품 원칙](docs/product-principles.md)
- [로컬 패키징과 릴리스 절차](docs/releasing.md)
- 전체 검증: `bash scripts/check`
- Aqua GUI E2E: `bash scripts/check-e2e`
- 실제 Codex CLI acceptance: `bash scripts/check-codex-cli-acceptance`

## 라이선스

[MIT License](LICENSE)
