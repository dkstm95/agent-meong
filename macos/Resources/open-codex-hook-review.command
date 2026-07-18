#!/bin/zsh

set -u

cd "$HOME" || exit 1

# The app's Connect action always installs in the default user Codex home.
# Shell startup files may export a separate CODEX_HOME, so pin the review CLI
# to the same location rather than approving an unrelated configuration.
export CODEX_HOME="$HOME/.codex"

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
capability_pid=
capability_root=
current_uid=$(/usr/bin/id -u) || exit 1
# zsh otherwise renices background capability probes. Finder-launched apps can
# run without permission to change niceness, which would print a misleading
# warning in the review Terminal before Codex opens.
unsetopt BG_NICE

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

stop_capability_probe() {
    local pid=${capability_pid:-}
    local children child
    if [[ "$pid" == <-> ]]; then
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
    fi
    capability_pid=
    if [[ -n "${capability_root:-}" ]]; then
        /bin/rm -rf -- "$capability_root"
        capability_root=
    fi
}

trap 'stop_capability_probe; stop_shell_probe; exit 1' HUP INT TERM

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

accept_capable_candidate() {
    local candidate=$1
    local resolved_candidate candidate_directory candidate_path_prefix
    local attempts=0 probe_succeeded=false

    resolve_safe_executable "$candidate" || return 1
    resolved_candidate=$REPLY
    candidate_directory=${candidate:h}
    candidate_path_prefix=
    if resolve_safe_executable "$candidate_directory/node"; then
        candidate_path_prefix=$candidate_directory
    fi

    # A present executable is not sufficient: independently updated ChatGPT,
    # Codex, and standalone installations can expose different app-server
    # protocols. Generate the protocol schema in a private temporary directory
    # and accept only a candidate that advertises the hooks/list method used by
    # the current /hooks review surface.
    capability_root=$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/agent-meong-codex-capability.XXXXXX") || return 1
    /bin/chmod 700 "$capability_root" || {
        stop_capability_probe
        return 1
    }
    if [[ -n "$candidate_path_prefix" ]]; then
        PATH="$candidate_path_prefix:$PATH" "$resolved_candidate" \
            app-server generate-json-schema --out "$capability_root" \
            >/dev/null 2>&1 &
    else
        "$resolved_candidate" app-server generate-json-schema \
            --out "$capability_root" >/dev/null 2>&1 &
    fi
    capability_pid=$!
    while (( attempts < 30 )) && kill -0 "$capability_pid" 2>/dev/null; do
        /bin/sleep 0.1
        (( attempts += 1 ))
    done
    if kill -0 "$capability_pid" 2>/dev/null; then
        stop_capability_probe
        return 1
    fi
    if wait "$capability_pid" 2>/dev/null; then
        probe_succeeded=true
    fi
    capability_pid=
    if ! $probe_succeeded \
        || ! /usr/bin/grep -R -q -F '"hooks/list"' "$capability_root" \
            2>/dev/null
    then
        stop_capability_probe
        return 1
    fi
    /bin/rm -rf -- "$capability_root"
    capability_root=

    codex_path_prefix=$candidate_path_prefix
    codex_path=$resolved_candidate
}

# Prefer the auto-updated app bundle when it is available so an older
# standalone CLI cannot open a review surface that lacks current hooks.
for app_path in \
    "/Applications/ChatGPT.app" \
    "$HOME/Applications/ChatGPT.app" \
    "/Applications/Codex.app" \
    "$HOME/Applications/Codex.app"
do
    candidate="$app_path/Contents/Resources/codex"
    if accept_capable_candidate "$candidate"; then
        break
    fi
done

if [[ -z "$codex_path" ]]; then
    for candidate in \
        "$HOME/.local/bin/codex" \
        "$HOME/.codex/bin/codex" \
        "/opt/homebrew/bin/codex" \
        "/usr/local/bin/codex"
    do
        if accept_capable_candidate "$candidate"; then
            break
        fi
    done
fi

if [[ -z "$codex_path" ]]; then
    # Finder-launched apps do not inherit the user's shell PATH. Bound the
    # login-shell fallback so unusual shell startup files cannot leave the UI
    # in an opening state forever. Keep the resolved path in memory only.
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
    accept_capable_candidate "$candidate" || true
fi

if [[ -z "$codex_path" ]]; then
    if $check_only; then
        exit 1
    fi
    print 'agent-meong could not find a compatible Codex App or Codex CLI.'
    print 'Install or update Codex, then choose “Open Codex review” again.'
    print '호환되는 Codex App 또는 Codex CLI를 찾지 못했습니다.'
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
