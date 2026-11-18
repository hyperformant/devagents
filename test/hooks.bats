#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  unset CI
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cp "$ROOT/lefthook/devagents.yml" "$BATS_TEST_TMPDIR/devagents.yml"
  git -C "$REPO" init -q
  printf 'extends:\n  - %s\n' "$BATS_TEST_TMPDIR/devagents.yml" > "$REPO/lefthook.yml"
  git -C "$REPO" add lefthook.yml
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
}

# Runs `lefthook run <hook>` in the temp repo with stdin closed.
hook() { cd "$REPO" && run lefthook run "$1" < /dev/null; }
stage() { git -C "$REPO" add "$@"; }

@test "staged script with SC2086 blocks and names the file" {
  printf '#!/bin/bash\necho $1\n' > "$REPO/bad.sh"
  stage bad.sh
  hook pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *bad.sh* ]]
  [[ "$output" == *SC2086* ]]
}

@test "extensionless bash shebang script is checked" {
  mkdir "$REPO/bin"
  printf '#!/bin/bash\necho $1\n' > "$REPO/bin/tool"
  stage bin/tool
  hook pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *SC2086* ]]
}

@test "unstaged bad file is ignored" {
  printf '#!/bin/bash\necho $1\n' > "$REPO/bad.sh"
  hook pre-commit
  [ "$status" -eq 0 ]
}

@test "clean staged change passes" {
  printf '#!/bin/bash\necho "$1"\n' > "$REPO/ok.sh"
  stage ok.sh
  hook pre-commit
  [ "$status" -eq 0 ]
}

@test "CI=true skips" {
  printf '#!/bin/bash\necho $1\n' > "$REPO/bad.sh"
  stage bad.sh
  CI=true hook pre-commit
  [ "$status" -eq 0 ]
  [[ "$output" != *SC2086* ]]
}

@test "PATH without shellcheck skips the job and passes" {
  printf '#!/bin/bash\necho $1\n' > "$REPO/bad.sh"
  stage bad.sh
  # PATH holds only symlinks to what the hook needs, resolved up front, so
  # this passes even where shellcheck lives in /usr/bin.
  local bin="$BATS_TEST_TMPDIR/bin" t
  mkdir "$bin"
  for t in git sh bash jq lefthook; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  # A mise shim would re-add shellcheck, so link the real binary if shimmed.
  if command -v mise > /dev/null 2>&1; then
    ln -sf "$(mise which lefthook 2> /dev/null || command -v lefthook)" "$bin/lefthook"
  fi
  local saved="$PATH"
  PATH="$bin"
  ! command -v shellcheck
  hook pre-commit
  PATH="$saved"
  [ "$status" -eq 0 ]
  [[ "$output" == *"devagents-shellcheck (skip)"* ]]
}

@test "bad workflow is blocked by actionlint" {
  mkdir -p "$REPO/.github/workflows"
  printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ bogus.x }}\n' \
    > "$REPO/.github/workflows/ci.yml"
  stage .github/workflows/ci.yml
  hook pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *ci.yml* ]]
}

@test "nested docker/app/Dockerfile with an untagged FROM is blocked by hadolint" {
  mkdir -p "$REPO/docker/app"
  printf 'FROM ubuntu\nRUN true\n' > "$REPO/docker/app/Dockerfile"
  stage docker/app/Dockerfile
  hook pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *DL3006* ]]
}

@test "package.json dupes script exiting 1 blocks" {
  printf '{"scripts":{"dupes":"echo found-dupes; exit 1"}}\n' > "$REPO/package.json"
  hook pre-push
  [ "$status" -ne 0 ]
  [[ "$output" == *found-dupes* ]]
}

@test "no package.json skips dupes and unused" {
  hook pre-push
  [ "$status" -eq 0 ]
  [[ "$output" == *"devagents-dupes (skip)"* ]]
  [[ "$output" == *"devagents-unused (skip)"* ]]
}

@test "remote config loads from a file:// bare repo at a ref" {
  local bare="$BATS_TEST_TMPDIR/remote.git" work="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$bare"
  git init -q "$work"
  mkdir -p "$work/lefthook"
  cp "$ROOT/lefthook/devagents.yml" "$work/lefthook/devagents.yml"
  git -C "$work" add .
  git -C "$work" -c user.name=t -c user.email=t@t commit -q -m init
  git -C "$work" tag v1
  git -C "$work" push -q "$bare" HEAD:refs/heads/main v1
  cat > "$REPO/lefthook.yml" <<YML
remotes:
  - git_url: file://$bare
    ref: v1
    refetch_frequency: 24h
    configs:
      - lefthook/devagents.yml
YML
  printf '#!/bin/bash\necho $1\n' > "$REPO/bad.sh"
  stage bad.sh
  hook pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *SC2086* ]]
}

@test "unreachable remote warns and the hook still exits 0" {
  cat > "$REPO/lefthook.yml" <<YML
remotes:
  - git_url: file:///nonexistent/devagents
    ref: v1
    refetch_frequency: 24h
    configs:
      - lefthook/devagents.yml
YML
  printf '#!/bin/bash\necho "$1"\n' > "$REPO/ok.sh"
  stage ok.sh
  hook pre-commit
  [ "$status" -eq 0 ]
  [[ "$output" == *nonexistent* ]]
}

@test "a subscriber's own pre-commit job still runs under CI=true" {
  cat >> "$REPO/lefthook.yml" <<YML
pre-commit:
  jobs:
    - name: mine
      run: touch "$BATS_TEST_TMPDIR/marker"
YML
  echo x > "$REPO/file.txt"
  stage file.txt
  CI=true hook pre-commit
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/marker" ]
}
