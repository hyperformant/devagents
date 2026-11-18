#!/usr/bin/env bash
# Run the subscribe eval hermetically: dry run, no token, fake gh first on PATH.
# `claude plugin eval` only lets cases set EVAL_* env, so the operator shell sets the rest.
# Usage: evals/run-subscribe.sh [extra claude plugin eval args]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DEVAGENTS_DRY_RUN=1
export CLAUDE_CODE_OAUTH_TOKEN=""
# subscribe.sh reads its token from $HOME/.config/devagents; point HOME at an empty dir,
# and keep Claude's own login by pinning its config dir to the real one.
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export HOME="$tmp/home"
mkdir -p "$HOME"
export GH_LOG="$tmp/gh.log" GH_STDIN_LOG="$tmp/gh.stdin"
export PATH="$repo/test/bin:$PATH"
cd "$here/.."
claude plugin eval . --case 'subscribe*' --no-publish --trust-plugin \
  --allow-tools 'Bash(bash *)' "$@"
