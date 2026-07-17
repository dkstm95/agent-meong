#!/bin/zsh

set -u

cd "$HOME" || exit 1

check_only=false
if [[ $# -eq 1 && $1 == "--check" ]]; then
    check_only=true
elif [[ $# -ne 0 ]]; then
    print -u2 'usage: open-codex-hook-review.command [--check]'
    exit 2
fi

codex_path=
codex_path_prefix=
shell_pid=
current_uid=$(/usr/bin/id -u) || exit 1

stop_shell_probe() {
    local pid=${shell_pid:-}
    local children child
    [[ "$pid" == <-> ]] || return 0
    children=$(/usr/bin/pgrep -P "$pid" 2>/dev/null || true)
    for child in ${(f)children}; do
        [[ "$child" == <-> ]] || continue
        /bin/kill -TERM "$child" 2>/dev/null || true
    done
    /bin/kill -TERM "$pid" 2>/dev/null || true
    /bin/sleep 0.1
    for child in ${(f)children}; do
        [[ "$child" == <-> ]] || continue
        /bin/kill -KILL "$child" 2>/dev/null || true
    done
    /bin/kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    shell_pid=
}

trap 'stop_shell_probe; exit 1' HUP INT TERM

resolve_safe_executable() {
    local candidate=$1
    local resolved metadata owner permissions

    REPLY=
    [[ "$candidate" == /* && "$candidate" != *$'\n'* ]] || return 1
    resolved=${candidate:A}
    [[ -f "$resolved" && -x "$resolved" ]] || return 1
    metadata=$(/usr/bin/stat -f '%u %Lp' -- "$resolved" 2>/dev/null) || return 1
    owner=${metadata%% *}
    permissions=${metadata##* }
    (( owner == 0 || owner == current_uid )) || return 1
    (( (8#$permissions & 8#22) == 0 )) || return 1
    REPLY=$resolved
}

accept_candidate() {
    local candidate=$1
    local resolved_candidate candidate_directory

    resolve_safe_executable "$candidate" || return 1
    resolved_candidate=$REPLY
    candidate_directory=${candidate:h}
    codex_path_prefix=
    if resolve_safe_executable "$candidate_directory/node"; then
        codex_path_prefix=$candidate_directory
    fi
    codex_path=$resolved_candidate
}

for candidate in \
    "$HOME/.local/bin/codex" \
    "$HOME/.codex/bin/codex" \
    "/opt/homebrew/bin/codex" \
    "/usr/local/bin/codex"
do
    if accept_candidate "$candidate"; then
        break
    fi
done

if [[ -z "$codex_path" ]]; then
    # A safe, fixed standalone CLI above is the clearest review target. The
    # app bundle is the next stable fallback; shell discovery stays last.
    for app_path in \
        "/Applications/ChatGPT.app" \
        "$HOME/Applications/ChatGPT.app" \
        "/Applications/Codex.app" \
        "$HOME/Applications/Codex.app"
    do
        candidate="$app_path/Contents/Resources/codex"
        if accept_candidate "$candidate"; then
            break
        fi
    done
fi

if [[ -z "$codex_path" ]]; then
    # Finder-launched apps do not inherit the user's shell PATH. Bound the
    # login-shell fallback so unusual shell startup files cannot leave the UI
    # in an opening state forever. Keep the resolved path in memory only.
    unsetopt BG_NICE
    coproc /bin/zsh -lic '
        candidate=${commands[codex]-}
        if [[ "$candidate" == /* ]]; then
            print -r -- "__AGENT_MEONG_CODEX__${candidate}"
        fi
    '
    shell_pid=$!
    candidate=
    attempts=0
    while (( attempts < 50 )); do
        if IFS= read -r -p -t 0.1 line 2>/dev/null; then
            if [[ "$line" == __AGENT_MEONG_CODEX__/* ]]; then
                candidate=${line#__AGENT_MEONG_CODEX__}
            fi
        fi
        if ! kill -0 "$shell_pid" 2>/dev/null; then
            break
        fi
        (( attempts += 1 ))
    done
    if kill -0 "$shell_pid" 2>/dev/null; then
        stop_shell_probe
        candidate=
    else
        wait "$shell_pid" 2>/dev/null || true
        shell_pid=
    fi
    accept_candidate "$candidate" || true
fi

if [[ -z "$codex_path" ]]; then
    if $check_only; then
        exit 1
    fi
    print 'agent-meong could not find Codex App or Codex CLI.'
    print 'Install or update Codex, then choose “Open Codex review” again.'
    print 'Codex App 또는 Codex CLI를 찾지 못했습니다.'
    print 'Codex를 설치·업데이트한 뒤 “Codex 검토 열기”를 다시 눌러 주세요.'
    print
    read -k 1 '?Press any key to close. / 아무 키나 누르면 닫힙니다. '
    exit 1
fi

if $check_only; then
    exit 0
fi

if [[ -n "$codex_path_prefix" ]]; then
    export PATH="$codex_path_prefix:$PATH"
fi
exec "$codex_path"
