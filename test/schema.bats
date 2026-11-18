#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CENTRAL="$ROOT/schema/devagents.schema.json"
  REPO="$ROOT/schema/repo-config.schema.json"
  FIX="$BATS_TEST_DIRNAME/fixtures/schema"
}

central() { run check-jsonschema --schemafile "$CENTRAL" "$FIX/$1"; }
repo() { run check-jsonschema --schemafile "$REPO" "$FIX/$1"; }

@test "the shipped devagents.yml is valid" {
  run check-jsonschema --schemafile "$CENTRAL" "$ROOT/devagents.yml"
  [ "$status" -eq 0 ]
}

@test "both schemas pass --check-metaschema" {
  run check-jsonschema --check-metaschema "$CENTRAL" "$REPO"
  [ "$status" -eq 0 ]
}

@test "schedule trigger without schedule is rejected" {
  central central-schedule-no-schedule.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *schedule* ]]
}

@test "effort ultra is rejected" {
  central central-effort-ultra.yml
  [ "$status" -ne 0 ]
}

@test "unknown job key foo is rejected" {
  central central-unknown-key.yml
  [ "$status" -ne 0 ]
}

@test "model with a space or leading dash is rejected" {
  central central-model-space.yml
  [ "$status" -ne 0 ]
  central central-model-dash.yml
  [ "$status" -ne 0 ]
}

@test "model claude-opus-5-5[1m] is accepted" {
  central central-model-bracket.yml
  [ "$status" -eq 0 ]
}

@test "empty repo config is valid" {
  repo repo-empty.yml
  [ "$status" -eq 0 ]
}

@test "repo override of prompt is rejected" {
  repo repo-prompt-override.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *prompt* ]]
}

@test "nested with value is rejected" {
  repo repo-nested-with.yml
  [ "$status" -ne 0 ]
}

@test "skip, commands and test_budget are accepted" {
  repo repo-all-keys.yml
  [ "$status" -eq 0 ]
}

@test "repo override of allowed_tools is rejected" {
  repo repo-allowed-tools.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *allowed_tools* ]]
}

@test "allowed_tools items with injection or quotes are rejected" {
  central central-tools-injection.yml
  [ "$status" -ne 0 ]
  central central-tools-quote.yml
  [ "$status" -ne 0 ]
}

@test "defaults without allowed_tools are rejected" {
  central central-defaults-no-tools.yml
  [ "$status" -ne 0 ]
}
