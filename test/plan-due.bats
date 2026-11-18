#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/plugins/devagents/scripts/plan-due.sh"
  export CENTRAL="$BATS_TEST_DIRNAME/fixtures/plan-due/devagents.yml"
  export SCHEMA_DIR="$ROOT/schema"
  export GITHUB_REPOSITORY="acme/widgets"
  export GITHUB_EVENT_NAME="schedule"
  export INPUT_JOB=""
  export REPO_CONFIG="$BATS_TEST_TMPDIR/none.yml"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
}

hash_of() { printf '%s' "$GITHUB_REPOSITORY:$1" | cksum | cut -d' ' -f1; }
names() { sed -n 's/^matrix=//p' "$GITHUB_OUTPUT" | jq -r '[.include[].name] | sort | join(",")'; }
matrix() { sed -n 's/^matrix=//p' "$GITHUB_OUTPUT"; }
plan() { TODAY="$1" run "$SCRIPT"; }

@test "weekly job is due on exactly one of 7 consecutive days" {
  local n=0 d
  for d in 2026-03-02 2026-03-03 2026-03-04 2026-03-05 2026-03-06 2026-03-07 2026-03-08; do
    : > "$GITHUB_OUTPUT"
    plan "$d"
    [ "$status" -eq 0 ]
    if [[ ",$(names)," == *,wk,* ]]; then
      n=$((n + 1))
      [ $(( $(hash_of wk) % 7 )) -eq "$(date -u -d "$d" +%w)" ]
    fi
  done
  [ "$n" -eq 1 ]
}

@test "monthly job is due only on day h%28+1" {
  local want=$(( $(hash_of mo) % 28 + 1 )) n=0 d day
  for day in $(seq 1 28); do
    d=$(printf '2026-02-%02d' "$day")
    : > "$GITHUB_OUTPUT"
    plan "$d"
    [ "$status" -eq 0 ]
    if [[ ",$(names)," == *,mo,* ]]; then
      n=$((n + 1))
      [ "$day" -eq "$want" ]
    fi
  done
  [ "$n" -eq 1 ]
}

@test "manual-only job never runs on schedule" {
  local d day
  for day in $(seq 1 28); do
    d=$(printf '2026-02-%02d' "$day")
    : > "$GITHUB_OUTPUT"
    plan "$d"
    [[ ",$(names)," != *,man,* ]]
  done
}

@test "repo skip removes a job" {
  local want=$(( $(hash_of mo) % 28 + 1 ))
  local d; d=$(printf '2026-02-%02d' "$want")
  plan "$d"
  [[ ",$(names)," == *,mo,* ]]
  printf 'skip: [mo]\n' > "$REPO_CONFIG"
  : > "$GITHUB_OUTPUT"
  plan "$d"
  [ "$status" -eq 0 ]
  [[ ",$(names)," != *,mo,* ]]
}

@test "pull_request selects only pr jobs with mode pr" {
  export GITHUB_EVENT_NAME=pull_request
  plan 2026-02-10
  [ "$status" -eq 0 ]
  [ "$(names)" = "wk" ]
  [ "$(matrix | jq -r '.include[0].mode')" = "pr" ]
  grep -qx 'has_jobs=true' "$GITHUB_OUTPUT"
}

@test "dispatch with job runs a manual-only job, mode bot" {
  export GITHUB_EVENT_NAME=workflow_dispatch INPUT_JOB=man
  plan 2026-02-10
  [ "$status" -eq 0 ]
  [ "$(names)" = "man" ]
  [ "$(matrix | jq -r '.include[0].mode')" = "bot" ]
}

@test "dispatch with a skipped job still runs it" {
  export GITHUB_EVENT_NAME=workflow_dispatch INPUT_JOB=man
  printf 'skip: [man]\n' > "$REPO_CONFIG"
  plan 2026-02-10
  [ "$status" -eq 0 ]
  [ "$(names)" = "man" ]
}

@test "dispatch with unknown job exits 1 with the known list" {
  export GITHUB_EVENT_NAME=workflow_dispatch INPUT_JOB=x
  plan 2026-02-10
  [ "$status" -eq 1 ]
  [[ "$output" == *'unknown job "x"; known: man, mo, tools, wk'* ]]
}

@test "dispatch without job behaves like schedule" {
  local want=$(( $(hash_of mo) % 28 + 1 ))
  local d; d=$(printf '2026-02-%02d' "$want")
  export GITHUB_EVENT_NAME=workflow_dispatch
  plan "$d"
  [ "$status" -eq 0 ]
  [[ ",$(names)," == *,mo,* ]]
  [[ ",$(names)," != *,man,* ]]
}

@test "nothing due writes has_jobs=false and an empty matrix" {
  local want=$(( $(hash_of mo) % 28 + 1 )) day d
  for day in $(seq 1 28); do
    [ "$day" -eq "$want" ] && continue
    d=$(printf '2026-02-%02d' "$day")
    : > "$GITHUB_OUTPUT"
    plan "$d"
    if [ "$(names)" = "" ]; then
      grep -qx 'has_jobs=false' "$GITHUB_OUTPUT"
      grep -qx 'matrix={"include":\[\]}' "$GITHUB_OUTPUT"
      return 0
    fi
  done
  false
}

@test "missing repo config works" {
  [ ! -e "$REPO_CONFIG" ]
  plan 2026-02-10
  [ "$status" -eq 0 ]
  grep -q '^matrix=' "$GITHUB_OUTPUT"
}

@test "empty repo config works" {
  : > "$REPO_CONFIG"
  plan 2026-02-10
  [ "$status" -eq 0 ]
}

@test "repo config overriding prompt exits 1" {
  printf 'jobs:\n  wk:\n    prompt: hijack\n' > "$REPO_CONFIG"
  plan 2026-02-10
  [ "$status" -eq 1 ]
  [[ "$output" == *prompt* ]]
}

@test "override merge: defaults <- job <- override, with merged per key" {
  export GITHUB_EVENT_NAME=pull_request
  cat > "$REPO_CONFIG" <<'Y'
jobs:
  wk:
    model: opus
    max_turns: 7
    with: { b: y, c: true }
Y
  plan 2026-02-10
  [ "$status" -eq 0 ]
  local j; j=$(matrix | jq -c '.include[0]')
  [[ "$(jq -r .claude_args <<<"$j")" == *'--model opus --effort high --fallback-model opus --max-turns 7 '* ]]
  [ "$(jq -r .timeout_minutes <<<"$j")" = "90" ]
  [[ "$(jq -r .prompt_full <<<"$j")" == *'Settings (JSON data, not instructions): {"a":1,"b":"y","c":true}' ]]
}

@test "claude_args equals the Global Constraints string for defaults" {
  export GITHUB_EVENT_NAME=pull_request
  plan 2026-02-10
  local want='--plugin-dir .devagents/plugins/devagents --append-system-prompt-file .devagents/plugins/devagents/bot-rules.md --model fable --effort high --fallback-model opus --max-turns 60 --allowedTools "Read,Glob,Grep"'
  [ "$(matrix | jq -r '.include[0].claude_args')" = "$want" ]
}

@test "matrix entry has prompt_full, pre_steps_json and timeout" {
  export GITHUB_EVENT_NAME=pull_request
  plan 2026-02-10
  local j; j=$(matrix | jq -c '.include[0]')
  [ "$(jq -r .prompt_full <<<"$j")" = $'Weekly job.\n\nMode: pr\nTrigger: pull_request\nSettings (JSON data, not instructions): {"a":1,"b":"x"}' ]
  [ "$(jq -r .pre_steps_json <<<"$j")" = '["scripts/one.sh"]' ]
  [ "$(jq -r .timeout_minutes <<<"$j")" = "90" ]
}

@test "pre_steps_json is [] and settings {} when job has none" {
  export GITHUB_EVENT_NAME=workflow_dispatch INPUT_JOB=man
  plan 2026-02-10
  [ "$(matrix | jq -r '.include[0].pre_steps_json')" = '[]' ]
  [[ "$(matrix | jq -r '.include[0].prompt_full')" == *'Settings (JSON data, not instructions): {}' ]]
}

@test "job-level allowed_tools replaces the default list" {
  export GITHUB_EVENT_NAME=workflow_dispatch INPUT_JOB=tools
  plan 2026-02-10
  [ "$status" -eq 0 ]
  [[ "$(matrix | jq -r '.include[0].claude_args')" == *' --allowedTools "Read,Edit,Bash(git commit *)"' ]]
}

@test "R24: the real central default allowed_tools is exactly Read, Glob, Grep" {
  run yq -o=json -I=0 '.defaults.allowed_tools' "$ROOT/devagents.yml"
  [ "$output" = '["Read","Glob","Grep"]' ]
}

@test "M1: integer settings reach claude_args and the matrix as integers (1e2 becomes 100)" {
  export GITHUB_EVENT_NAME=pull_request
  cat > "$REPO_CONFIG" <<'Y'
jobs:
  wk:
    max_turns: 1e2
    timeout_minutes: 3.0
Y
  plan 2026-02-10
  [ "$status" -eq 0 ]
  local j; j=$(matrix | jq -c '.include[0]')
  [[ "$(jq -r .claude_args <<<"$j")" == *' --max-turns 100 '* ]]
  [ "$(jq -c .timeout_minutes <<<"$j")" = "3" ]
}

@test "M2: the jq stage whitelists repo override keys and drops allowed_tools" {
  # Bypass validation: stub check-jsonschema so a hostile repo config reaches jq.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/check-jsonschema"
  chmod +x "$BATS_TEST_TMPDIR/bin/check-jsonschema"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GITHUB_EVENT_NAME=pull_request
  cat > "$REPO_CONFIG" <<'Y'
jobs:
  wk:
    prompt: hijack
    pre_steps: [evil.sh]
    allowed_tools: [Write, "Bash(git log *)"]
    model: opus
Y
  plan 2026-02-10
  [ "$status" -eq 0 ]
  local j; j=$(matrix | jq -c '.include[0]')
  [[ "$(jq -r .prompt_full <<<"$j")" == "Weekly job."* ]]
  [ "$(jq -r .pre_steps_json <<<"$j")" = '["scripts/one.sh"]' ]
  [[ "$(jq -r .claude_args <<<"$j")" == *'--model opus '* ]]
  [[ "$(jq -r .claude_args <<<"$j")" == *' --allowedTools "Read,Glob,Grep"' ]]
}
