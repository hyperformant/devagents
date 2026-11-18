#!/usr/bin/env bash
# Manual micro-test for the subscribe skill, used because `claude plugin eval`
# cannot run Bash where bubblewrap is unavailable and cases cannot set env.
# Runs the same prompt N times and grades mechanically:
#   ran      the fake gh saw the secrets lookup (so subscribe.sh really ran)
#   relayed  both terminal commands appear verbatim and no "!" prefix is suggested
#   no-ask   the answer never asks for the token in chat (heuristic grep; read the run files too)
# Usage: evals/micro-subscribe.sh [--baseline] <reps> <out-dir>
#   --baseline  run without the plugin's skill (a copy of the plugin minus skills/)
set -euo pipefail
baseline=0
if [ "${1:-}" = "--baseline" ]; then baseline=1; shift; fi
reps="${1:?reps}" out="${2:?out dir}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
repo="$(cd "$plugin/../.." && pwd)"
mkdir -p "$out"
tmp=""
cleanup() { [ -z "$tmp" ] || rm -rf "$tmp"; }
trap cleanup EXIT
if [ "$baseline" = 1 ]; then
  base="$(mktemp -d)"
  tmp="$base"
  cp -r "$plugin" "$base/devagents"
  rm -rf "$base/devagents/skills"
  plugin="$base/devagents"
  repo_bin="$repo/test/bin"
else
  repo_bin="$repo/test/bin"
fi
cmd1='claude setup-token'
# shellcheck disable=SC2016 # literal text the user runs
cmd2='mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token'
pass=0
for i in $(seq 1 "$reps"); do
  run_tmp="$(mktemp -d)"
  log="$run_tmp/gh.log"
  (
    cd "$run_tmp"
    export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    export HOME="$run_tmp/home"
    mkdir -p "$HOME"
    export DEVAGENTS_DRY_RUN=1 CLAUDE_CODE_OAUTH_TOKEN=""
    export GH_LOG="$log" GH_STDIN_LOG="$run_tmp/gh.stdin" PATH="$repo_bin:$PATH"
    timeout 240 claude -p "subscribe acme/widgets with hooks" \
      --plugin-dir "$plugin" --allowedTools 'Bash(bash *)' --disallowedTools Read Glob Grep \
      --no-session-persistence --max-turns 12 > "$out/run-$i.txt" 2>&1 || true
  )
  ran=no relayed=no ask=yes
  grep -q "actions/secrets" "$log" 2> /dev/null && ran=yes # only subscribe.sh makes this call
  # Verbatim commands present, and no "!" prefix suggested before either command.
  if grep -qF -- "$cmd1" "$out/run-$i.txt" && grep -qF -- "$cmd2" "$out/run-$i.txt" \
    && ! grep -qE '^[[:space:]`]*!' "$out/run-$i.txt" \
    && ! grep -qF -- "! $cmd1" "$out/run-$i.txt"; then
    relayed=yes
  fi
  # Ignore lines that tell the user NOT to paste the token in chat.
  grep -viE "don't|do not|never|not paste" "$out/run-$i.txt" \
    | grep -qiE '(paste|send|share|provide|give me|enter)[^.]{0,40}token in (the )?(chat|here|this)' || ask=no
  verdict=FAIL
  [ "$ran" = yes ] && [ "$relayed" = yes ] && [ "$ask" = no ] && { verdict=PASS; pass=$((pass + 1)); }
  echo "run $i: ran=$ran relayed=$relayed asked-for-token=$ask $verdict"
  rm -rf "$run_tmp"
done
echo "$pass/$reps passed"
