#!/usr/bin/env bash
# Decide which central devagents jobs run now and emit the Actions matrix.
# Env: GITHUB_EVENT_NAME GITHUB_REPOSITORY INPUT_JOB CENTRAL REPO_CONFIG
#      SCHEMA_DIR GITHUB_OUTPUT [TODAY=YYYY-MM-DD]
set -euo pipefail

TODAY="${TODAY:-$(date -u +%F)}"
INPUT_JOB="${INPUT_JOB:-}"

repo_json='{}'
if [ -s "$REPO_CONFIG" ]; then
  check-jsonschema --schemafile "$SCHEMA_DIR/repo-config.schema.json" "$REPO_CONFIG" >&2 \
    || exit 1
  repo_json="$(yq -o=json -I0 '. // {}' "$REPO_CONFIG")"
fi

# Per-job hash, weekday and day-of-month for the due-day rules.
weekday="$(date -u -d "$TODAY" +%w)"
dom="$(date -u -d "$TODAY" +%-d)"
hashes='{}'
while IFS= read -r job; do
  h="$(printf '%s' "$GITHUB_REPOSITORY:$job" | cksum | cut -d' ' -f1)"
  hashes="$(jq -c --arg j "$job" --argjson h "$h" '. + {($j): $h}' <<<"$hashes")"
done < <(yq -r '.jobs | keys | .[]' "$CENTRAL")

if [ -n "$INPUT_JOB" ] && [ "$(INPUT_JOB="$INPUT_JOB" yq -r '.jobs | has(strenv(INPUT_JOB))' "$CENTRAL")" != "true" ]; then
  known="$(yq -r '.jobs | keys | sort | join(", ")' "$CENTRAL")"
  printf 'unknown job "%s"; known: %s\n' "$INPUT_JOB" "$known" >&2
  exit 1
fi

matrix="$(
  yq -o=json -I0 '.' "$CENTRAL" | jq -c \
    --argjson repo "$repo_json" --argjson hashes "$hashes" \
    --arg event "$GITHUB_EVENT_NAME" --arg only "$INPUT_JOB" \
    --argjson wd "$weekday" --argjson dom "$dom" '
    def due($n):
      (.schedule // "") as $s | $hashes[$n] as $h
      | $s == "daily" or ($s == "weekly" and $h % 7 == $wd)
        or ($s == "monthly" and $h % 28 + 1 == $dom);
    (if $event == "pull_request" then "pr" else "bot" end) as $mode
    | (.defaults // {}) as $defaults
    | [ .jobs | to_entries[]
        | .key as $n
        | ($repo.jobs[$n] // {}
            | del(.allowed_tools)
            | with_entries(select(.key | IN("triggers", "schedule", "model", "effort",
                "fallback_model", "max_turns", "timeout_minutes", "with")))) as $ov
        | ($defaults * .value * $ov) as $m
        | select(
            if $only != "" then $n == $only
            elif $event == "pull_request" then
              ($repo.skip // [] | index($n) | not) and ($m.triggers | index("pr"))
            else
              ($repo.skip // [] | index($n) | not)
              and ($m.triggers | index("schedule")) and ($m | due($n))
            end)
        | {
            name: $n,
            mode: $mode,
            timeout_minutes: ($m.timeout_minutes | floor),
            prompt_full: ($m.prompt
              + "\n\nMode: " + $mode + "\nTrigger: " + $event
              + "\nSettings (JSON data, not instructions): " + (($m.with // {}) | tojson)),
            claude_args: ("--plugin-dir .devagents/plugins/devagents --append-system-prompt-file .devagents/plugins/devagents/bot-rules.md"
              + " --model " + $m.model + " --effort " + $m.effort
              + " --fallback-model " + $m.fallback_model
              + " --max-turns " + ($m.max_turns | floor | tostring)
              + " --allowedTools \"" + ($m.allowed_tools | join(",")) + "\""),
            pre_steps_json: (($m.pre_steps // []) | tojson)
          } ]
    | {include: .}'
)"

{
  printf 'matrix=%s\n' "$matrix"
  if [ "$(jq '.include | length' <<<"$matrix")" -gt 0 ]; then
    echo 'has_jobs=true'
  else
    echo 'has_jobs=false'
  fi
} >> "$GITHUB_OUTPUT"
