#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/plugins/devagents/scripts/subscribe.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/subscribe"
  export PATH="$BATS_TEST_DIRNAME/bin:$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  # Isolation: the real token file and git config must never be touched.
  # mise shims resolve tools through HOME, so pin mise to the real dirs first.
  export MISE_DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share/mise}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-$HOME/.config/mise}"
  export MISE_CACHE_DIR="${MISE_CACHE_DIR:-$HOME/.cache/mise}" MISE_STATE_DIR="${MISE_STATE_DIR:-$HOME/.local/state/mise}"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-must-be-ignored"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  unset CLAUDE_CODE_OAUTH_TOKEN DEVAGENTS_DRY_RUN CI
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_STDIN_LOG="$BATS_TEST_TMPDIR/gh.stdin"
  export LH_LOG="$BATS_TEST_TMPDIR/lh.log"
  : > "$GH_LOG"; : > "$GH_STDIN_LOG"; : > "$LH_LOG"
  export FAKE_ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  export FAKE_SECRETS="$FIX/gh/secrets-present.json"
  export REPO="acme/widgets"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK"
}

# R19: setup steps are for the user's own terminal, never the "!" prefix.
assert_terminal_lines() {
  local want
  want='In your own terminal (not through Claude), run:
  claude setup-token
  mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token
Then re-run the subscribe command.'
  [[ "$output" == *"$want"* ]]
  [[ "$output" != *'!'* ]]
}
sub() { run bash "$SCRIPT" "$@"; }
# File content on the pushed subscribe branch.
pushed() { git -C "$FAKE_ORIGIN" show "devagents/subscribe:$1"; }
pushed_has() { git -C "$FAKE_ORIGIN" cat-file -e "devagents/subscribe:$1" 2> /dev/null; }
cron_for() {
  local h
  h="$(printf '%s' "$1:cron" | cksum | cut -d' ' -f1)"
  printf '%s %s * * *' $((h % 60)) $(((h / 60) % 24))
}
count_log() { grep -c -- "$1" "$GH_LOG" || true; }
# Re-run against what the first run pushed: that tree becomes the default branch.
overlay_from_push() {
  local o="$BATS_TEST_TMPDIR/overlay"
  rm -rf "$o"; mkdir -p "$o"
  git -C "$FAKE_ORIGIN" archive devagents/subscribe | tar -x -C "$o"
  export FAKE_OVERLAY="$o"
  rm -rf "$FAKE_ORIGIN"
  : > "$GH_LOG"
}

@test "fresh repo without --hooks plans only the stub, cron from cksum" {
  export FAKE_REPO=fresh-js
  sub "$REPO"
  [ "$status" -eq 0 ]
  local wf; wf="$(pushed .github/workflows/devagents.yml)"
  [[ "$wf" == *"cron: '$(cron_for "$REPO")'"* ]]
  [[ "$wf" != *__CRON_* ]]
  ! pushed_has lefthook.yml
  # package.json untouched
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/fresh-js/package.json")" ]
  [ "$(count_log 'pr create')" -eq 1 ]
  grep -q -- '--title Subscribe to hyperformant/devagents' "$GH_LOG"
  [ ! -s "$LH_LOG" ]
}

@test "cron is identical across runs" {
  export FAKE_REPO=fresh-js
  sub "$REPO"; [ "$status" -eq 0 ]
  local first; first="$(pushed .github/workflows/devagents.yml)"
  rm -rf "$FAKE_ORIGIN"
  sub "$REPO"; [ "$status" -eq 0 ]
  [ "$(pushed .github/workflows/devagents.yml)" = "$first" ]
}

@test "stub already on default branch: already subscribed, no branch, no PR" {
  export FAKE_REPO=fresh-js
  sub "$REPO"; [ "$status" -eq 0 ]
  overlay_from_push
  sub "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already subscribed"* ]]
  [ "$(count_log 'pr create')" -eq 0 ]
  [ "$(count_log 'pr list')" -eq 0 ]
  ! git -C "$FAKE_ORIGIN" rev-parse --verify -q devagents/subscribe
}

@test "open PR on devagents/subscribe: branch updated, no second pr create" {
  export FAKE_REPO=fresh-js FAKE_REMOTE_BRANCH=devagents/subscribe
  export FAKE_PR_LIST="$FIX/gh/pr-open.json"
  sub "$REPO"
  [ "$status" -eq 0 ]
  [ "$(count_log 'pr create')" -eq 0 ]
  grep -q -- '--head devagents/subscribe --state open --json number' "$GH_LOG"
  [[ "$(pushed .github/workflows/devagents.yml)" == *"cron: '$(cron_for "$REPO")'"* ]]
  # recreated from the default branch: exactly one commit on top of main
  [ "$(git -C "$FAKE_ORIGIN" rev-list --count main..devagents/subscribe)" -eq 1 ]
}

@test "--hooks fresh-js: lefthook.yml remotes entry, prepare is lefthook install || true" {
  export FAKE_REPO=fresh-js
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  pushed lefthook.yml > "$BATS_TEST_TMPDIR/lh.yml"
  [ "$(yq '.remotes | length' "$BATS_TEST_TMPDIR/lh.yml")" -eq 1 ]
  [ "$(yq '.remotes[0].git_url' "$BATS_TEST_TMPDIR/lh.yml")" = "https://github.com/hyperformant/devagents" ]
  [ "$(yq '.remotes[0].ref' "$BATS_TEST_TMPDIR/lh.yml")" = "v1" ]
  [ "$(yq '.remotes[0].refetch_frequency' "$BATS_TEST_TMPDIR/lh.yml")" = "24h" ]
  [ "$(yq '.remotes[0].configs[0]' "$BATS_TEST_TMPDIR/lh.yml")" = "lefthook/devagents.yml" ]
  [ "$(pushed package.json | jq -r .scripts.prepare)" = "lefthook install || true" ]
  [ "$(pushed package.json | jq -r .scripts.test)" = "echo ok" ]
  [ -n "$(pushed package.json | tail -c1 | od -An -c | grep '\\n')" ]
  [[ "$(pushed package.json)" == *'  "name"'* ]]
}

@test "--hooks existing prepare is kept, joined with && and a guarded lefthook install" {
  export FAKE_REPO=has-lefthook
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [ "$(pushed package.json | jq -r .scripts.prepare)" = "echo prep && (lefthook install || true)" ]
}

@test "--hooks fresh-py: lefthook.yml, no package.json, note to run lefthook install" {
  export FAKE_REPO=fresh-py
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  pushed_has lefthook.yml
  ! pushed_has package.json
  [[ "$output" == *"run: lefthook install"* ]]
}

@test "--hooks has-lefthook: remotes entry added once, comments kept; rerun adds none" {
  export FAKE_REPO=has-lefthook
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  local y; y="$(pushed lefthook.yml)"
  [[ "$y" == *"# my hooks"* ]]
  [[ "$y" == *"name: mine"* ]]
  [ "$(yq '[.remotes[] | select(.git_url == "https://github.com/hyperformant/devagents")] | length' <<< "$y")" -eq 1 ]
  [ "$(pushed package.json | jq -r .scripts.prepare)" = "echo prep && (lefthook install || true)" ]
  overlay_from_push
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"already subscribed"* ]]
  [ "$(count_log 'pr create')" -eq 0 ]
}

@test "--hooks matches an existing remotes entry by git_url only" {
  export FAKE_REPO=has-lefthook
  local o="$BATS_TEST_TMPDIR/ov"; mkdir -p "$o"
  printf 'remotes:\n  - git_url: https://github.com/hyperformant/devagents\n    ref: v0\n' > "$o/lefthook.yml"
  export FAKE_OVERLAY="$o"
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [ "$(pushed lefthook.yml | yq '.remotes | length')" -eq 1 ]
  [ "$(pushed lefthook.yml | yq '.remotes[0].ref')" = "v0" ]
}

@test "--hooks vibecarbon-like: hook files untouched, migration note, stub still planned" {
  export FAKE_REPO=vibecarbon-like
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"core.hooksPath"* ]]
  [[ "$output" == *"lefthook install --reset-hooks-path"* ]]
  [[ "$output" == *"port"* ]]
  pushed_has .github/workflows/devagents.yml
  ! pushed_has lefthook.yml
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/vibecarbon-like/package.json")" ]
  [ "$(count_log 'pr create')" -eq 1 ]
}

@test "--hooks husky: hook files untouched, migration note, stub still planned" {
  export FAKE_REPO=husky
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"husky"* ]]
  [[ "$output" == *"lefthook install --reset-hooks-path"* ]]
  pushed_has .github/workflows/devagents.yml
  ! pushed_has lefthook.yml
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/husky/package.json")" ]
  [ "$(pushed .husky/pre-commit)" = "$(cat "$FIX/repos/husky/.husky/pre-commit")" ]
}

@test "--hooks with .pre-commit-config.yaml is another manager" {
  export FAKE_REPO=fresh-py
  local o="$BATS_TEST_TMPDIR/ov"; mkdir -p "$o"
  printf 'repos: []\n' > "$o/.pre-commit-config.yaml"
  export FAKE_OVERLAY="$o"
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit"* ]]
  ! pushed_has lefthook.yml
  pushed_has .github/workflows/devagents.yml
}

@test "other manager and stub present: already subscribed" {
  export FAKE_REPO=husky
  sub "$REPO" --hooks; [ "$status" -eq 0 ]
  overlay_from_push
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"already subscribed"* ]]
}

@test "no token and no secret: exit 2 printing the two setup lines, no writes" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json"
  sub "$REPO"
  [ "$status" -eq 2 ]
  assert_terminal_lines
  [ "$(count_log 'secret set')" -eq 0 ]
  [ ! -e "$FAKE_ORIGIN" ]
}

@test "org secret counts as present" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json" FAKE_ORG_SECRETS="$FIX/gh/secrets-present.json"
  sub "$REPO"
  [ "$status" -eq 0 ]
  [ "$(count_log 'secret set')" -eq 0 ]
}

@test "token from env reaches secret set on stdin only, never argv" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json"
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat-SECRET123"
  sub "$REPO"
  [ "$status" -eq 0 ]
  [ "$(count_log 'secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/widgets')" -eq 1 ]
  ! grep -q SECRET123 "$GH_LOG"
  [ "$(cat "$GH_STDIN_LOG")" = "sk-ant-oat-SECRET123" ]
  [[ "$output" != *SECRET123* ]]
}

@test "token from $HOME/.config/devagents (XDG_CONFIG_HOME ignored) works and is not echoed" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json"
  mkdir -p "$HOME/.config/devagents" "$XDG_CONFIG_HOME/devagents"
  printf 'filetok-XYZ' > "$HOME/.config/devagents/claude-token"
  printf 'wrong-XDG' > "$XDG_CONFIG_HOME/devagents/claude-token"
  sub "$REPO"
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_STDIN_LOG")" = "filetok-XYZ" ]
  ! grep -q filetok "$GH_LOG"
  [[ "$output" != *filetok* ]]
}

# $WORK is a clone of the repo with a lefthook config, so arming WOULD run
# if dry run failed to prevent it.
armed_work() {
  git init -q "$WORK"
  git -C "$WORK" remote add origin "https://github.com/$REPO"
  echo 'pre-commit: {}' > "$WORK/lefthook.yml"
  WORK_SNAP="$(cd "$WORK" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cksum)"
}
assert_dry_run_wrote_nothing() {
  [ "$(count_log 'secret set')" -eq 0 ]
  [ "$(count_log 'pr list')" -eq 0 ]
  [ "$(count_log 'pr create')" -eq 0 ]
  ! git -C "$FAKE_ORIGIN" rev-parse --verify -q devagents/subscribe
  [ -z "$(git -C "$FAKE_ORIGIN" for-each-ref refs/heads | grep -v refs/heads/main || true)" ]
  [ ! -s "$LH_LOG" ]
  [ "$(cd "$WORK" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cksum)" = "$WORK_SNAP" ]
}

@test "--dry-run prints a diff and writes nothing" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json" CLAUDE_CODE_OAUTH_TOKEN=tok
  armed_work
  sub "$REPO" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"+++ b/.github/workflows/devagents.yml"* ]]
  [[ "$output" == *"+++ b/lefthook.yml"* ]]
  assert_dry_run_wrote_nothing
}

@test "DEVAGENTS_DRY_RUN=1 with a token and a missing secret writes nothing" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json" CLAUDE_CODE_OAUTH_TOKEN=tok DEVAGENTS_DRY_RUN=1
  armed_work
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"+++ b/.github/workflows/devagents.yml"* ]]
  assert_dry_run_wrote_nothing
  [ ! -s "$GH_STDIN_LOG" ]
}

@test "DEVAGENTS_DRY_RUN=1 with no token still exits 2 after read-only checks" {
  export FAKE_REPO=fresh-js FAKE_SECRETS="$FIX/gh/secrets-none.json" DEVAGENTS_DRY_RUN=1
  sub "$REPO" --hooks
  [ "$status" -eq 2 ]
  assert_terminal_lines
  grep -q 'auth status' "$GH_LOG"
  grep -q 'actions/secrets' "$GH_LOG"
}

@test "missing Claude App is a warning with the install URL, not a failure" {
  export FAKE_REPO=fresh-js FAKE_INSTALLATIONS="$FIX/gh/installations-none.json"
  sub "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/apps/claude"* ]]
}

@test "gh not authenticated exits 1" {
  export FAKE_REPO=fresh-js FAKE_AUTH=fail
  sub "$REPO"
  [ "$status" -eq 1 ]
  [ "$(count_log 'pr create')" -eq 0 ]
}

@test "bad arguments exit 1" {
  sub
  [ "$status" -eq 1 ]
  sub not-a-repo
  [ "$status" -eq 1 ]
  sub "$REPO" --bogus
  [ "$status" -eq 1 ]
}

@test "--hooks in a local clone of the repo runs lefthook install there (https and ssh)" {
  export FAKE_REPO=has-lefthook
  local u
  for u in "https://github.com/acme/widgets.git" "git@github.com:acme/widgets"; do
    : > "$LH_LOG"; rm -rf "$FAKE_ORIGIN" "$WORK/.git"
    git init -q "$WORK"
    git -C "$WORK" remote add origin "$u"
    echo 'pre-commit: {}' > "$WORK/lefthook.yml"
    sub "$REPO" --hooks
    [ "$status" -eq 0 ]
    grep -q "^$WORK: install$" "$LH_LOG"
  done
}

@test "--hooks in an unrelated directory does not run lefthook install" {
  export FAKE_REPO=has-lefthook
  git init -q "$WORK"
  git -C "$WORK" remote add origin https://github.com/acme/other.git
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [ ! -s "$LH_LOG" ]
}

@test "--hooks in a local clone without a lefthook config does not create one" {
  export FAKE_REPO=fresh-js
  git init -q "$WORK"
  git -C "$WORK" remote add origin https://github.com/acme/widgets.git
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [ ! -s "$LH_LOG" ]
  [ ! -e "$WORK/lefthook.yml" ]
  [[ "$output" == *"run: lefthook install"* ]]
}

@test "works from a plugin directory copied alone (installed plugin, no repo root)" {
  local inst="$BATS_TEST_TMPDIR/installed"
  mkdir -p "$inst"
  cp -r "$ROOT/plugins/devagents" "$inst/devagents"
  export FAKE_REPO=fresh-js
  run bash "$inst/devagents/scripts/subscribe.sh" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$(pushed .github/workflows/devagents.yml)" == *"cron: '$(cron_for "$REPO")'"* ]]
}

@test "I4: lefthook.toml is a non-YAML config: no hook file changes, note to add the remotes entry by hand" {
  export FAKE_REPO=lefthook-toml
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  ! pushed_has lefthook.yml
  [ "$(pushed lefthook.toml)" = "$(cat "$FIX/repos/lefthook-toml/lefthook.toml")" ]
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/lefthook-toml/package.json")" ]
  [[ "$output" == *"lefthook.toml"* ]]
  [[ "$output" == *"remotes"* ]]
  pushed_has .github/workflows/devagents.yml
}

@test "I4: .config/lefthook.yml is YAML: remotes entry merged there, no new lefthook.yml" {
  export FAKE_REPO=config-lefthook
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  ! pushed_has lefthook.yml
  local y; y="$(pushed .config/lefthook.yml)"
  [[ "$y" == *"# my hooks"* ]]
  [ "$(yq '[.remotes[] | select(.git_url == "https://github.com/hyperformant/devagents")] | length' <<< "$y")" -eq 1 ]
  [ "$(pushed package.json | jq -r .scripts.prepare)" = "echo prep && (lefthook install || true)" ]
}

@test "I4: simple-git-hooks (package.json key) is another manager" {
  export FAKE_REPO=simple-git-hooks-key
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"simple-git-hooks"* ]]
  ! pushed_has lefthook.yml
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/simple-git-hooks-key/package.json")" ]
}

@test "I4: simple-git-hooks in prepare is another manager" {
  export FAKE_REPO=simple-git-hooks-prepare
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"simple-git-hooks"* ]]
  ! pushed_has lefthook.yml
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/simple-git-hooks-prepare/package.json")" ]
}

@test "I4: a top-level husky key in package.json is another manager" {
  export FAKE_REPO=husky-key
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"husky"* ]]
  ! pushed_has lefthook.yml
  [ "$(pushed package.json)" = "$(cat "$FIX/repos/husky-key/package.json")" ]
}

# A PATH holding only the named tools (plus bash/dirname), so the rest are "not installed".
limited_path() {
  local d="$BATS_TEST_TMPDIR/limited" t
  rm -rf "$d"; mkdir -p "$d"
  for t in bash dirname "$@"; do
    ln -s "$(command -v "$t")" "$d/$t"
  done
  echo "$d"
}

@test "I5: missing jq exits 1 before any gh call" {
  export FAKE_REPO=fresh-js
  run env PATH="$(limited_path gh git yq)" bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: jq (install: mise use -g jq)"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "I5: missing yq is fatal only with --hooks" {
  export FAKE_REPO=fresh-js
  run env PATH="$(limited_path gh git jq)" bash "$SCRIPT" "$REPO" --hooks
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: yq (install: mise use -g yq)"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "I5: missing gh exits 1" {
  run env PATH="$(limited_path git jq yq)" bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tool: gh (install: mise use -g gh)"* ]]
}

@test "M5: Acme/Widgets and acme/widgets render the same cron, from the canonical name" {
  export FAKE_REPO=fresh-js
  sub "Acme/Widgets"
  [ "$status" -eq 0 ]
  [[ "$(pushed .github/workflows/devagents.yml)" == *"cron: '$(cron_for acme/widgets)'"* ]]
  grep -q 'repo view Acme/Widgets' "$GH_LOG"
  grep -q -- '--repo acme/widgets' "$GH_LOG"
  ! grep -q -- '--repo Acme/Widgets' "$GH_LOG"
}

@test "M4: PR body mentions hooks only when hooks were wired" {
  export FAKE_REPO=fresh-js
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  grep -q 'quick-check git hooks through lefthook' "$GH_LOG"
  rm -rf "$FAKE_ORIGIN"; : > "$GH_LOG"
  export FAKE_REPO=husky
  sub "$REPO" --hooks
  [ "$status" -eq 0 ]
  ! grep -q 'quick-check git hooks through lefthook' "$GH_LOG"
  grep -q 'migration notes were printed instead' "$GH_LOG"
  rm -rf "$FAKE_ORIGIN"; : > "$GH_LOG"
  export FAKE_REPO=fresh-js
  sub "$REPO"
  ! grep -qi 'hook' <(grep 'pr create' "$GH_LOG")
}

@test "I5: a yq failure on an existing lefthook.yml aborts instead of being swallowed" {
  export FAKE_REPO=has-lefthook
  local o="$BATS_TEST_TMPDIR/ov"; mkdir -p "$o"
  printf 'remotes: [unclosed\n' > "$o/lefthook.yml"
  export FAKE_OVERLAY="$o"
  sub "$REPO" --hooks
  [ "$status" -ne 0 ]
  [ "$(count_log 'pr create')" -eq 0 ]
}
