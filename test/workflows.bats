#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  RUN="$ROOT/.github/workflows/run-due.yml"
  STUB="$ROOT/plugins/devagents/templates/subscriber-workflow.yml"
}

@test "stub permissions equal the Global Constraints set" {
  run yq -o=json -I=0 '.permissions | to_entries | sort_by(.key) | from_entries' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '{"actions":"read","checks":"read","contents":"write","id-token":"write","issues":"write","pull-requests":"write","statuses":"read"}' ]
}

@test "stub triggers" {
  run yq '.on.schedule | length' "$STUB"
  [ "$output" = "1" ]
  run yq '.on.schedule[0].cron' "$STUB"
  [ "$output" = "__CRON_MINUTE__ __CRON_HOUR__ * * *" ]
  run yq -o=json -I=0 '.on.pull_request.types' "$STUB"
  [ "$output" = '["opened","reopened","ready_for_review"]' ]
  run yq '.on.workflow_dispatch.inputs.job.type' "$STUB"
  [ "$output" = "string" ]
}

@test "R26: stub calls run-due.yml@main passing the secret explicitly, never inherit" {
  run yq '.jobs.devagents.uses' "$STUB"
  [ "$output" = "hyperformant/devagents/.github/workflows/run-due.yml@main" ]
  run yq -o=json -I=0 '.jobs.devagents.secrets' "$STUB"
  [ "$output" = '{"CLAUDE_CODE_OAUTH_TOKEN":"${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}"}' ]
  ! grep -q 'secrets: inherit' "$STUB"
  run yq '.jobs.devagents.with.job' "$STUB"
  [ "$output" = '${{ inputs.job }}' ]
}

@test "run-due is a workflow_call with the expected inputs and secret" {
  run yq '.on.workflow_call.inputs.toolkit_ref.default' "$RUN"
  [ "$output" = "main" ]
  run yq '.on.workflow_call.secrets.CLAUDE_CODE_OAUTH_TOKEN.required' "$RUN"
  [ "$output" = "true" ]
}

@test "plan job if: equals the PR guard expression" {
  run yq '.jobs.plan.if' "$RUN"
  [ "$output" = "github.event_name != 'pull_request' || (github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON('[\"OWNER\",\"MEMBER\",\"COLLABORATOR\"]'), github.event.pull_request.author_association))" ]
}

@test "plan job reads repo config at the default branch" {
  run yq '.jobs.plan.steps[] | select(.with.path == "repo") | .with.ref' "$RUN"
  [ "$output" = '${{ github.event.repository.default_branch }}' ]
}

@test "every uses: is one of the three exact pinned strings" {
  run bash -c "yq '.jobs[].steps[] | select(.uses) | .uses' '$RUN' | sort -u"
  [ "$status" -eq 0 ]
  want=$'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\nanthropics/claude-code-action@469588f42e6b1e94cd14ad09dccfeaec772ce0fd\njdx/mise-action@236a21c3b91f5db6d4e174b348674a0f0caac06d'
  [ "$output" = "$want" ]
}

@test "every checkout sets persist-credentials: false" {
  run yq '[.jobs[].steps[] | select(.uses | test("^actions/checkout@")) | .with."persist-credentials"] | unique' -o=json -I=0 "$RUN"
  [ "$output" = "[false]" ]
  run yq '[.jobs[].steps[] | select(.uses | test("^actions/checkout@"))] | length' "$RUN"
  [ "$output" = "4" ]
}

@test "run job permissions equal the stub's" {
  run yq -o=json -I=0 '.jobs.run.permissions | to_entries | sort_by(.key) | from_entries' "$RUN"
  [ "$output" = '{"actions":"read","checks":"read","contents":"write","id-token":"write","issues":"write","pull-requests":"write","statuses":"read"}' ]
}

@test "run job removes tracked toolkit paths between subscriber and toolkit checkouts" {
  run yq '.jobs.run.steps[1].run' "$RUN"
  [ "$output" = "rm -rf .devagents .devagents-out" ]
  run yq '.jobs.run.steps[0].with.fetch-depth, .jobs.run.steps[2].with.path' "$RUN"
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = ".devagents" ]
}

@test "pre-steps validate the JSON and do not swallow jq errors" {
  run yq '.jobs.run.steps[] | select(.name == "Pre-steps") | .run' "$RUN"
  [[ "$output" == *"jq -e 'type == \"array\""* ]]
  [[ "$output" == *"mapfile -t steps < <(jq -r '.[]'"* ]]
  [[ "$output" != *"done < <("* ]]
}

@test "run job: max-parallel 1, fail-fast false, timeout from matrix, concurrency per job and PR" {
  run yq '.jobs.run.strategy."max-parallel"' "$RUN"
  [ "$output" = "1" ]
  run yq '.jobs.run.strategy."fail-fast"' "$RUN"
  [ "$output" = "false" ]
  run yq '.jobs.run."timeout-minutes"' "$RUN"
  [ "$output" = '${{ matrix.timeout_minutes }}' ]
  run yq '.jobs.run.concurrency.group' "$RUN"
  [[ "$output" == *'matrix.name'* ]]
  [[ "$output" == *'github.event.pull_request.number'* ]]
}

@test "no expressions inside run: script bodies" {
  run bash -c "yq '.jobs[].steps[].run // \"\"' '$RUN' | grep -F '\${{' || true"
  [ -z "$output" ]
}

@test "bot rules forbid touching toolkit dirs" {
  grep -qF 'Never modify `.devagents/` or `.devagents-out/`.' "$ROOT/plugins/devagents/bot-rules.md"
}

@test "ci.yml runs on pull_request and push to main; all uses: SHA-pinned" {
  CI_YML="$ROOT/.github/workflows/ci.yml"
  run yq -o=json -I=0 '.on | keys' "$CI_YML"
  [ "$output" = '["pull_request","push"]' ]
  run yq -o=json -I=0 '.on.push.branches' "$CI_YML"
  [ "$output" = '["main"]' ]
  run yq -o=json -I=0 '.jobs | keys' "$CI_YML"
  [ "$output" = '["ci"]' ]
  run yq -o=json -I=0 '.permissions' "$CI_YML"
  [ "$output" = '{"contents":"read"}' ]
  run yq '[.jobs.ci.steps[] | select(.uses | test("^actions/checkout@")) | .with."persist-credentials"] | .[0]' "$CI_YML"
  [ "$output" = "false" ]
  run bash -c "yq '.jobs[].steps[] | select(.uses) | .uses' '$CI_YML' | grep -vE '@[0-9a-f]{40}\$' || true"
  [ -z "$output" ]
}

@test "release.yml is workflow_dispatch with a validated version input and exact permissions" {
  REL="$ROOT/.github/workflows/release.yml"
  run yq -o=json -I=0 '.on | keys' "$REL"
  [ "$output" = '["workflow_dispatch"]' ]
  run yq '.on.workflow_dispatch.inputs.version.required' "$REL"
  [ "$output" = "true" ]
  run yq -o=json -I=0 '.permissions | to_entries | sort_by(.key) | from_entries' "$REL"
  [ "$output" = '{"actions":"read","contents":"write"}' ]
  run yq '[.jobs[].steps[].run // ""] | join("\n")' "$REL"
  [[ "$output" == *'^[0-9]+\.[0-9]+\.[0-9]+$'* ]]
  [[ "$output" == *'gh release create'* ]]
  [[ "$output" == *'git/refs'* ]]
}

@test "release.yml has no expressions inside run: bodies" {
  run bash -c "yq '.jobs[].steps[].run // \"\"' '$ROOT/.github/workflows/release.yml' | grep -F '\${{' || true"
  [ -z "$output" ]
}

@test "ci.yml installs the pinned Claude CLI explicitly, checks its version, then validates both targets" {
  CI_RUN="$(yq '[.jobs.ci.steps[].run // ""] | join("\n")' "$ROOT/.github/workflows/ci.yml")"
  [[ "$CI_RUN" == *'npm install --global @anthropic-ai/claude-code@2.1.327'* ]]
  [[ "$CI_RUN" == *'claude --version'* ]]
  [[ "$CI_RUN" == *'2.1.327'* ]]
  [[ "$CI_RUN" == *'claude plugin validate --strict .'* ]]
  [[ "$CI_RUN" == *'claude plugin validate --strict plugins/devagents'* ]]
  [[ "$CI_RUN" != *npx* ]]
}

@test "mise.toml pins node exactly, not claude-code" {
  grep -qE '^node = "24\.[0-9]+\.[0-9]+"$' "$ROOT/mise.toml"
  ! grep -q claude "$ROOT/mise.toml"
}

@test "mise.toml pins nr and the lockfile records it" {
  grep -qF '"npm:@antfu/ni" = "30.6.0"' "$ROOT/mise.toml"
  grep -qF 'npm:@antfu/ni' "$ROOT/mise.lock"
}

@test "R25: MISE_CEILING_PATHS is set on both plan and run jobs; run installs only ripgrep and yq" {
  run yq '.jobs.plan.env.MISE_CEILING_PATHS' "$RUN"
  [ "$output" = '${{ github.workspace }}' ]
  run yq '.jobs.run.env.MISE_CEILING_PATHS' "$RUN"
  [ "$output" = '${{ github.workspace }}' ]
  run yq '.jobs.run.steps[] | select(.uses | test("^jdx/mise-action@")) | .with.install_args' "$RUN"
  [ "$output" = 'ripgrep yq' ]
  run yq '.jobs.plan.steps[] | select(.uses | test("^jdx/mise-action@")) | .with.install_args' "$RUN"
  [ "$output" = 'yq uv python pipx:check-jsonschema' ]
}

@test "M9: claude_args plugin dir is the plugin itself in every doc" {
  ! grep -rn -- '--plugin-dir .devagents/plugins ' "$ROOT/docs" "$ROOT/plugins" "$ROOT/README.md" "$ROOT/CLAUDE.md"
}

@test "M7: release job only runs from main and moves v1 only for 1.x versions" {
  REL="$ROOT/.github/workflows/release.yml"
  run yq '.jobs.release.if' "$REL"
  [ "$output" = "github.ref == 'refs/heads/main'" ]
  run yq '[.jobs[].steps[].run // ""] | join("\n")' "$REL"
  [[ "$output" == *'"$VERSION" == 1.*'* ]]
  [[ "$output" == *'not moving v1'* ]]
}
