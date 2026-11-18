# devagents Foundation Implementation Plan (Plan 1 of 3, rev 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Rev 2 (2026-11-17), at Brandon's direction:** don't write logic that can be installed and used off the shelf.
- Hand-written config validation, tool provisioning, the hook loader and hook-file editing, the PR guard code and the Node test harness are all replaced with installable tools.
- What remains is bash glue that no tool provides: due-job selection and subscribing.

**Goal:** Ship the subscribable toolkit's plumbing, verified end to end on a sandbox repo:
- the plugin and marketplace
- the central job config with its JSON Schemas
- the shared lefthook quick-check config
- the reusable Actions workflow with a `smoke` job
- `/devagents:subscribe`

**Architecture:**
- **Built from off-the-shelf parts:**
  - mise installs and pins every CLI tool (`mise.toml` + `mise.lock`, `jdx/mise-action` in CI).
  - lefthook runs local hooks: subscriber repos list `hyperformant/devagents` as a lefthook **remote** at ref `v1`.
  - JSON Schema + check-jsonschema validate config.
  - yq and jq merge config and build the Actions matrix.
  - gh does every GitHub operation.
  - bats-core tests everything.
- **Our own code:** two bash scripts inside the plugin (`plan-due.sh`, `subscribe.sh`), plus workflow YAML.

**Tech Stack:** bash, mise, lefthook, check-jsonschema, yq, jq, bats-core, gh, GitHub Actions, `anthropics/claude-code-action`. There is no Node code in this plan.

**Spec:** `docs/superpowers/specs/2026-11-17-devagents-design.md` (see its "Revision 2" note).

**Plans 2 and 3:**
- Plan 2 is `codebase-audit`, plus the command contract via ni's `nr` and the `commands:` map.
- Plan 3 is `test-compactor`.
- They follow this plan, and their extension points are marked "Plan 2/3 hook".

## Global Constraints

- **Off the shelf first.** Never hand-write what an installable tool does. Glue scripts are bash with `set -euo pipefail`, must be shellcheck-clean, and live in `plugins/devagents/scripts/`.
- **Repo and names:** repo `hyperformant/devagents`, **public**. Marketplace `devagents`, plugin `devagents`, skills `/devagents:<name>`.
- **No central subscriber list.**
  - The stub `.github/workflows/devagents.yml` in each repo is the subscription.
  - Per-repo config is `.github/devagents.yml`.
- **Central defaults (`devagents.yml`):** `model: fable`, `effort: high`, `fallback_model: opus`, `max_turns: 60`, `timeout_minutes: 90`.
- **Tool pins (`mise.toml`, exact):**
  - `shellcheck = "0.11.0"`
  - `actionlint = "1.7.12"`
  - `hadolint = "2.15.1"`
  - `lefthook = "2.2.2"`
  - `yq = "4.54.3"`
  - `bats = "1.14.0"`
  - `"pipx:check-jsonschema" = "0.39.0"`
  - `ripgrep`: the latest version, pinned exactly

  `mise.lock` is committed, and CI installs with `--locked`.
- **Pinned actions:**
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7`
  - `jdx/mise-action@236a21c3b91f5db6d4e174b348674a0f0caac06d # v5.2.9`
  - `anthropics/claude-code-action@469588f42e6b1e94cd14ad09dccfeaec772ce0fd # v1`
- **CI's Claude CLI:** `@anthropic-ai/claude-code@2.1.327`.
- **Schedules:**
  - Values are `daily`, `weekly` or `monthly`.
  - `h = $(printf '%s' "<owner/repo>:<job>" | cksum | cut -d' ' -f1)`.
  - weekly is due when `h % 7` equals the UTC weekday (`date -u +%w`); monthly is due when `h % 28 + 1` equals the UTC day of month.
- **Stub cron:** `h = cksum("<owner/repo>:cron")`; minute `h % 60`; hour `(h / 60) % 24`; cron `"<minute> <hour> * * *"`.
- **Triggers:**
  - The values are `schedule`, `pr` and `manual`.
  - `pull_request` events run in mode `pr`; `schedule` and `workflow_dispatch` run in mode `bot`.
- **PR guard (R33):** a workflow `if:` on the plan job, exactly:
  ```
  github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)
  ```
  Any other event, including `pull_request_target`, is skipped. A `perm` step then checks the author's real repo permission (`gh api repos/$REPO/collaborators/$AUTHOR/permission`) and trusts only `admin` or `write`. Anything else fails closed: the step succeeds with `trusted=false` and `plan-due.sh` is skipped. `author_association` is not used.
- **Config trust:** the subscriber's `.github/devagents.yml` is always read from the **default branch**, never from a PR head.
- **Config validation:**
  - `model` and `fallback_model` match `^[A-Za-z0-9][A-Za-z0-9._\[\]-]*$`.
  - `effort` is one of `low|medium|high|xhigh|max`.
  - `max_turns` is an integer from 1 to 500; `timeout_minutes` is an integer from 1 to 360.
  - `with` values are scalars (string, number or boolean).
- **Repo overrides:** only `triggers`, `schedule`, `model`, `effort`, `fallback_model`, `max_turns`, `timeout_minutes` and `with` can be overridden (`with` merges per key). `prompt` and `pre_steps` cannot be overridden.
- **`claude_args`**, exactly:
  ```
  --plugin-dir .devagents/plugins/devagents --append-system-prompt-file .devagents/plugins/devagents/bot-rules.md --model <model> --effort <effort> --fallback-model <fallback_model> --max-turns <max_turns> --allowedTools "<allowed_tools joined with ,>"
  ```
- **Least-privilege tools (rev 2b, ruling R13):**
  - **Where it's set:** `allowed_tools` is a list set in central `defaults`, and optionally per central job. Repos **cannot** override it.
  - **Default (R24):** exactly `[Read, Glob, Grep]`. No `Bash(...)` entries: `git log --output=<file>` writes files and `git -c` runs programs. Git data reaches the agent through pre-steps.
  - **Bash rules always name a subcommand, and that subcommand's flags must be audited.** Write `Bash(wc *)`, never `Bash(git *)`; even a named subcommand can be unsafe (`git log --output`). There is no `find`, `rg`, `xargs`, shell, or bare `gh`, because `git -c alias`, `find -exec`, `rg --pre` and `gh extension` all execute arbitrary code.
  - **Item pattern:** `^(Read|Glob|Grep|Edit|Write|Bash\([a-z][a-z0-9_-]*( [a-z][a-z0-9_-]+)* \*\))$`.
  - **Later plans:** Plan 2/3 jobs add exactly the git/gh subcommands they need.
  - **Checkouts** use `persist-credentials: false` unless a step needs the token.
- **Hooks:**
  - The lefthook remote is `git_url: https://github.com/hyperformant/devagents`, `ref: v1`, `refetch_frequency: 24h`, `configs: [lefthook/devagents.yml]`.
  - Hooks never block on infrastructure:
    - `$CI` set → the hook is skipped.
    - A tool not installed → that job is skipped.
    - The remote unreachable → lefthook warns and continues.
    - `--no-verify` always works.
- **Stub permissions:**
  - `contents`, `pull-requests`, `issues`: write
  - `id-token`: write
  - `checks`, `statuses`, `actions`: read
- **Secrets and models:**
  - Secret name `CLAUDE_CODE_OAUTH_TOKEN`.
  - It is passed to `gh secret set` on stdin only, never in argv.
- **Attribution:** commits end with `Claude-Session: https://claude.ai/code/session_01SK1vqPMPsjBtWRjHaLfaqk`.

## Review Focus

1. **A repo with no `package.json` and no `.github/devagents.yml`** (Python, Rust) must plan, subscribe and run hooks without error:
   - its pre-push `dupes`/`unused` jobs are skipped
   - `subscribe --hooks` adds no `prepare` and notes `lefthook install`

   Owned by Tasks 2, 3 and 5.
2. **First hook run while offline:** the lefthook remote is unreachable, and the commit proceeds with lefthook's warning. Owned by Task 3.
3. **A repo that already has a hook manager** (`core.hooksPath` set in `prepare` like vibecarbon, `.husky/`, or `.pre-commit-config.yaml`): `subscribe --hooks` must not touch its hooks. It prints migration notes and still opens the stub PR. Owned by Task 5.
4. **Dispatch with a misspelled job name** exits 1 with `unknown job "x"; known: smoke`. Owned by Task 2.
5. **Re-running subscribe** must produce:
   - no duplicate PR
   - an unchanged cron
   - no duplicate lefthook `remotes` entry

   Owned by Task 5.

---

### Task 1: Skeleton, toolchain, config schemas

(This reworks commit `d846437`, which hand-wrote config validation in Node.)

**Files:**
- Keep: `.claude-plugin/marketplace.json`, `plugins/devagents/.claude-plugin/plugin.json`, `plugins/devagents/README.md`, `LICENSE`, `devagents.yml`.
- Delete: `plugins/devagents/package.json`, `package-lock.json`, `.gitignore`, `lib/`, `test/`.
- Create:
  - `mise.toml`, `mise.lock`
  - `schema/devagents.schema.json`, `schema/repo-config.schema.json`
  - `test/schema.bats`, `test/fixtures/schema/*.yml`
- Modify: `devagents.yml`. Its first line becomes `# yaml-language-server: $schema=./schema/devagents.schema.json`.

**Interfaces:**
- Produces:
  - `schema/devagents.schema.json`, for the central `devagents.yml`.
  - `schema/repo-config.schema.json`, for a subscriber's `.github/devagents.yml`. Its top-level keys are `skip` (array of job names), `jobs` (overrides), `commands` (string→string, Plan 2 hook) and `test_budget` (object, Plan 3 hook). It has no other keys, and an empty file is valid.
  - Both schemas are JSON Schema draft 2020-12.
  - Validation command: `check-jsonschema --schemafile schema/<name>.schema.json <file>`.

- [ ] **Step 1: Pin the toolchain.** Write `mise.toml` (the `[tools]` pins from Global Constraints), run `mise lock`, then `mise install --locked`. Expected: every tool resolves.
- [ ] **Step 2: Remove the Node files** listed above.
- [ ] **Step 3: Write the failing `test/schema.bats`.** Each case runs `check-jsonschema`.
  - **Both schemas:**
    - `the shipped devagents.yml is valid`.
    - `both schemas pass --check-metaschema`.
  - **Central schema:**
    - `schedule trigger without schedule is rejected` (output mentions `schedule`).
    - `effort ultra is rejected`.
    - `unknown job key foo is rejected`.
    - `model with a space or leading dash is rejected`: covers `fable --dangerously-skip-permissions` and `-x`.
    - `model claude-opus-5-5[1m] is accepted`.
  - **Repo schema:**
    - `empty repo config is valid`.
    - `repo override of prompt is rejected` (output mentions `prompt`).
    - `nested with value is rejected` (`with: {a: {b: 1}}`).
    - `skip, commands and test_budget are accepted`.
- [ ] **Step 4: Run** `bats test/`. Expected: FAIL, because the schemas don't exist yet.
- [ ] **Step 5: Write the two schemas.** Jobs use `additionalProperties: false`; an `if`/`then` makes `schedule` required when `triggers` contains `"schedule"`. Job names match `^[a-z][a-z0-9-]*$`. Each `pre_steps` entry matches `^scripts/[A-Za-z0-9._/-]+$`.
- [ ] **Step 6: Run** `bats test/`, `claude plugin validate --strict .` and `claude plugin validate --strict plugins/devagents`. Expected: all pass.
- [ ] **Step 7: Commit** with `refactor: validate config with JSON Schema; pin tools with mise`.

### Task 2: `plan-due.sh`

**Files:**
- Create: `plugins/devagents/scripts/plan-due.sh`, `test/plan-due.bats`, `test/fixtures/plan-due/devagents.yml` (jobs `wk` weekly schedule+pr, `mo` monthly schedule, `man` manual)

**Interfaces:**
- Consumes: the schemas (Task 1).
- Produces: `plan-due.sh`.
  - **Env:** `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`, `INPUT_JOB` (may be empty), `CENTRAL` (path to central yml), `REPO_CONFIG` (path, may not exist), `SCHEMA_DIR`, `GITHUB_OUTPUT`, and optionally `TODAY` (`YYYY-MM-DD`; defaults to the UTC date).
  - **Output:** `matrix=<json>` and `has_jobs=true|false`, appended to `$GITHUB_OUTPUT`.
  - **Matrix:** `{"include":[{name, mode, timeout_minutes, prompt_full, claude_args, pre_steps_json}]}`.
  - **`prompt_full`:** `<prompt>` + `\n\nMode: <mode>\nTrigger: <GITHUB_EVENT_NAME>\nSettings: <with as compact JSON>`.
  - **Errors:** an invalid repo config exits 1 and prints check-jsonschema's output.

- [ ] **Step 1: Write the failing `test/plan-due.bats`.**
  - **Schedule events:**
    - `weekly job is due on exactly one of 7 consecutive days`.
    - `monthly job is due only on day h%28+1`.
    - `manual-only job never runs on schedule`.
    - `repo skip removes a job`.
  - **Pull requests:** `pull_request selects only pr jobs with mode pr`.
  - **Dispatch:**
    - `dispatch with job runs a manual-only job, mode bot`.
    - `dispatch with unknown job exits 1 with: unknown job "x"; known: man, mo, wk`.
    - `dispatch without job behaves like schedule`.
  - **Config:**
    - `missing repo config works` (Review Focus 1).
    - `repo config overriding prompt exits 1`.
    - `override merge: defaults ← job ← override, with merged per key`.
  - **Output:** `claude_args equals the Global Constraints string for defaults`.
- [ ] **Step 2: Run** `bats test/plan-due.bats`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
  - Merge with `yq eval-all` (the `*` deep merge).
  - Build the matrix with `jq`.
  - Compute due days with `cksum` and `date -u -d "$TODAY"`.
  - Validate the repo config with `check-jsonschema` when the file exists and is non-empty.
- [ ] **Step 4: Run** `bats test/` and shellcheck on the script. Expected: PASS, no findings.
- [ ] **Step 5: Commit** with `feat: plan-due job selection`.

### Task 3: Shared lefthook config

**Files:**
- Create: `lefthook/devagents.yml`, `lefthook.yml` (devagents dogfoods it: `extends: [lefthook/devagents.yml]`, plus a pre-push job `bats test/`), `test/hooks.bats`

**Interfaces:**
- Produces: `lefthook/devagents.yml`, the remote config subscribers load.
  - **pre-commit:**
    - `parallel: true`, with hook-level `skip: [{run: 'test -n "$CI"'}]`.
    - The jobs are `shellcheck`, `actionlint` and `hadolint`. Each runs on `{staged_files}` and is skipped via `skip: [{run: '! command -v <tool>'}]` when the tool is missing.
    - `shellcheck` selects files with `file_types: [text/x-shellscript]`.
    - `actionlint` selects `.github/workflows/*.yml` and `*.yaml`.
    - `hadolint` selects `Dockerfile`, `Dockerfile.*` and `*.dockerfile` at any depth.
  - **pre-push:**
    - Jobs `dupes` and `unused` run `nr <name>`.
    - Each is skipped when `nr` is missing or `package.json` has no such script (`! jq -e '.scripts.<name>' package.json`).
    - Plan 3 hook: test-compactor adds its warn-only growth job here.
  - **Rule:** the remote config must not set top-level options that would change a subscriber's own jobs (e.g. no `glob_matcher`).

- [ ] **Step 1: Write the failing `test/hooks.bats`.** Each case uses a temp git repo whose `lefthook.yml` extends a copy of `lefthook/devagents.yml`, and runs `lefthook run <hook>`.
  - **pre-commit:**
    - `staged script with SC2086 blocks and names the file`.
    - `extensionless bash shebang script is checked`.
    - `unstaged bad file is ignored`.
    - `clean staged change passes`.
    - `CI=true skips`.
    - `PATH without shellcheck skips the job and passes`.
    - `bad workflow is blocked by actionlint`.
    - `nested docker/app/Dockerfile with an untagged FROM is blocked by hadolint`.
  - **pre-push:**
    - `package.json dupes script exiting 1 blocks`.
    - `no package.json skips dupes and unused`.
  - **Remote:**
    - `remote config loads from a file:// bare repo at a ref`.
    - `unreachable remote warns and the hook still exits 0` (Review Focus 2).
- [ ] **Step 2: Run** `bats test/hooks.bats`. Expected: FAIL.
- [ ] **Step 3: Write `lefthook/devagents.yml` and the dogfood `lefthook.yml`.** Use only documented lefthook options.
- [ ] **Step 4: Run** `bats test/` and `lefthook validate`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat: shared lefthook quick checks`.

### Task 4: Reusable Actions workflow, stub, bot rules

**Files:**
- Create: `.github/workflows/run-due.yml`, `plugins/devagents/templates/subscriber-workflow.yml`, `plugins/devagents/bot-rules.md`, `test/workflows.bats`

**Interfaces:**
- Consumes: `plan-due.sh` (Task 2) and `mise.toml` (Task 1).
- Produces:
  - `run-due.yml` is `on: workflow_call`, with inputs `job` (string, default `""`) and `toolkit_ref` (string, default `main`), and the required secret `CLAUDE_CODE_OAUTH_TOKEN`.
  - The stub uses the placeholders `__CRON_MINUTE__` and `__CRON_HOUR__`.
  - Plan 2/3 hook: `pre_steps` write to `$DEVAGENTS_OUT` (`.devagents-out/`).

- [ ] **Step 1: Write the failing `test/workflows.bats`.** It inspects the YAML with `yq`.
  - **Stub:**
    - `stub permissions equal the Global Constraints set`.
    - `stub triggers`:
      - one `schedule` cron
      - `pull_request` types `[opened, reopened, ready_for_review]`
      - `workflow_dispatch` input `job`
    - `stub calls hyperformant/devagents/.github/workflows/run-due.yml@main and passes CLAUDE_CODE_OAUTH_TOKEN explicitly under secrets (R26, never inherit)`.
  - **`run-due.yml`:**
    - `plan job if: is only the fork check`, plus the `perm` step tests (env-only inputs, admin/write trusted, read/none/empty/gh-failure untrusted).
    - `plan job reads repo config at the default branch`.
    - `every uses: is pinned to a 40-hex SHA`.
    - `run job: max-parallel 1, fail-fast false, timeout-minutes from matrix, concurrency group includes job name and PR number`.
- [ ] **Step 2: Run** `bats test/workflows.bats`. Expected: FAIL.
- [ ] **Step 3: Write `run-due.yml`.**
  1. **`plan` job:**
     - Check out the toolkit at `inputs.toolkit_ref` into `.devagents`.
     - Do a sparse checkout of the subscriber's `.github/devagents.yml` at `github.event.repository.default_branch` into `repo`.
     - First, for `pull_request` events, a `perm` step (id `perm`) calls `gh api repos/$REPO/collaborators/$AUTHOR/permission` with `GH_TOKEN`, `REPO` and `AUTHOR` passed through `env:`. It writes `trusted=true` only for `admin` or `write`, and `trusted=false` otherwise, including on API errors (with a `::warning::`). It always exits 0.
     - Run `mise-action` with `working_directory: .devagents`, then `plan-due.sh` gated on `github.event_name != 'pull_request' || steps.perm.outputs.trusted == 'true'`. When it is skipped, the job outputs are empty and the `run` job's `has_jobs == 'true'` condition skips it.
  2. **`run` job:**
     - Check out the subscriber at `github.event.pull_request.head.sha || github.sha` with `fetch-depth: 0`, and the toolkit into `.devagents`.
     - Append `.devagents/` and `.devagents-out/` to `.git/info/exclude`.
     - Run `mise-action` (`.devagents`), which provides `rg`.
     - Run each `pre_steps` entry with `bash`.
     - Run `claude-code-action` with the matrix's `prompt_full` and `claude_args`.
- [ ] **Step 4: Write the stub and `bot-rules.md`.** The bot rules are the spec's bullets verbatim, plus "Never modify `.devagents/` or `.devagents-out/`."
- [ ] **Step 5: Run** `bats test/` and `actionlint` on the workflows and on a placeholder-substituted copy of the stub. Expected: PASS.
- [ ] **Step 6: Commit** with `feat: reusable run-due workflow and subscriber stub`.

### Task 5: `/devagents:subscribe`

**Files:**
- Create: `plugins/devagents/scripts/subscribe.sh`, `plugins/devagents/skills/subscribe/SKILL.md`, `plugins/devagents/evals/subscribe/`, `test/subscribe.bats`, `test/fixtures/subscribe/` (repos: `fresh-js`, `fresh-py`, `vibecarbon-like`, `husky`, `has-lefthook`), `test/bin/gh` (a fake gh that logs argv and stdin to `$GH_LOG` and serves canned responses)

**Interfaces:**
- Consumes: `plugins/devagents/templates/subscriber-workflow.yml` (Task 4).
- Produces: `subscribe.sh <owner/repo> [--hooks] [--dry-run]`.
  - **Exit codes:**
    - 0: done, or already subscribed
    - 2: a token is needed
    - 1: error
  - **Token source:** env `CLAUDE_CODE_OAUTH_TOKEN`, or the file `~/.config/devagents/claude-token`.
  - **`--dry-run`:** runs every read-only check, prints the planned file changes as a diff, and makes no writes. `DEVAGENTS_DRY_RUN=1` is equivalent (ruling R3).

- [ ] **Step 1: Write the failing `test/subscribe.bats`.** The fake `gh` is first on PATH, and `gh repo clone` copies a fixture.
  - **The stub:**
    - `fresh repo without --hooks plans only the stub, cron from cksum`.
    - `cron is identical across runs`.
    - `stub already on default branch → "already subscribed", no gh pr create`.
    - `open PR on devagents/subscribe → branch updated, no second gh pr create`.
  - **With `--hooks`:**
    - `--hooks fresh-js → lefthook.yml with the remotes entry, prepare "lefthook install || true" (an existing prepare kept, joined with " && ")`.
    - `--hooks fresh-py → lefthook.yml, no package.json, note "run: lefthook install"`.
    - `--hooks has-lefthook → remotes entry added once; rerun adds none`.
    - `--hooks vibecarbon-like and husky → hook files untouched, migration note printed, stub still planned` (Review Focus 3).
  - **The token:**
    - `no token and no secret → exit 2 printing the terminal-only setup lines (R19)`.
    - `the token never appears in any gh argv in $GH_LOG; secret set received it on stdin`.
- [ ] **Step 2: Run** `bats test/subscribe.bats`. Expected: FAIL.
- [ ] **Step 3: Implement `subscribe.sh`** with `gh`, `git`, `yq`, `jq` and `cksum`.
  1. `gh auth status`.
  2. **Best-effort Claude App check:** `gh api orgs/<owner>/installations` or `user/installations`, looking for `app_slug == "claude"`. If the call is forbidden, print `https://github.com/apps/claude` and continue.
  3. **Secret:** the repo or org secret must be present, or set it from the token source; otherwise exit 2. Ruling R19: the setup steps are for the user's own terminal, never Claude's `!` prefix, because `claude setup-token` prints the token and `read -s` needs a TTY. The script prints exactly:
     ```
     In your own terminal (not through Claude), run:
       claude setup-token
       mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token
     Then re-run the subscribe command.
     ```
  4. `gh repo clone <repo> <tmp> -- --depth 1`, then compute the changes.
  5. Update the existing `devagents/subscribe` PR branch, or create the branch, commit (`chore: subscribe to hyperformant/devagents`), push, and `gh pr create --title "Subscribe to hyperformant/devagents"`.
  6. With `--hooks`, when the cwd is a clone of the repo, run `lefthook install` there.
- [ ] **Step 4: Write the skill and its eval (RED → GREEN), per ruling R3.**
  - **Eval case:**
    - Prompt: "subscribe acme/widgets with hooks", run with `DEVAGENTS_DRY_RUN=1` and no token.
    - Graders: it ran `subscribe.sh … --hooks`; it relayed the terminal instructions verbatim without suggesting `!`; it did not ask for the token in chat.
  - **Baseline:** run `claude plugin eval plugins/devagents --case 'subscribe*'` before SKILL.md exists, and record the failures.
  - **SKILL.md:**
    - Description: "Use when subscribing a repository to hyperformant/devagents scheduled jobs or local quick-check git hooks, or repairing an existing subscription."
    - Body: run `bash <skill base dir>/../../scripts/subscribe.sh <owner/repo> [--hooks]`, relay its output, and on exit 2 relay the terminal instructions verbatim. Never suggest `!` for them, and never request the token in chat.
  - **Re-run:** the plugin arm passes.
- [ ] **Step 5: Verify.** Run `bats test/`, shellcheck, and `claude plugin validate --strict plugins/devagents`. Expected: PASS.
- [ ] **Step 6: Commit** with `feat: /devagents:subscribe`.

### Task 6: Toolkit CI, release, docs

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `README.md`, `CLAUDE.md`
- Modify: `test/workflows.bats`

- [ ] **Step 1: Extend `test/workflows.bats`.**
  - `ci.yml runs on pull_request and push to main; all uses: SHA-pinned`.
  - `release.yml is workflow_dispatch with input version matching ^\d+\.\d+\.\d+$ and permissions contents: write only`.
- [ ] **Step 2: Write `ci.yml`.**
  1. `mise-action` (locked).
  2. `bats test/`.
  3. `check-jsonschema --check-metaschema schema/*.json` and `check-jsonschema --schemafile schema/devagents.schema.json devagents.yml`.
  4. `actionlint`.
  5. `shellcheck plugins/devagents/scripts/*.sh`.
  6. `lefthook validate`.
  7. `npx -y @anthropic-ai/claude-code@2.1.327 plugin validate --strict` for `.` and for `plugins/devagents`.
- [ ] **Step 3: Write `release.yml`.**
  1. Check that `ci.yml` concluded `success` on the HEAD SHA of `main`.
  2. `gh release create v<version> --target <sha> --generate-notes`.
  3. `git tag -f v1 <sha> && git push -f origin v1`.
- [ ] **Step 4: Write the docs.**
  - **`README.md`:**
    - the spec's Developer-experience table
    - one-time machine setup: install mise, `mise use -g lefthook shellcheck actionlint hadolint npm:@antfu/ni`, and activate mise in the shell
    - Claude GitHub App install
    - `claude setup-token` and the token file
  - **`CLAUDE.md`:** the spec's Conventions plus the off-the-shelf rule. Before committing, run `bats test/` and `claude plugin validate --strict`.
- [ ] **Step 5: Run** `bats test/` and `actionlint`. Expected: PASS.
- [ ] **Step 6: Commit** with `ci: toolkit CI and release workflow; docs`.

### Task 7: Publish and end-to-end on the sandbox (outward-facing; confirm with Brandon first)

- [ ] **Step 1: Publish.**
  1. `gh repo create hyperformant/devagents --public --source . --push`.
  2. Protect `main`: require `ci`, no force-push.
  3. Run `release.yml` with `version: 1.0.0`. Expected: tags `v1.0.0` and `v1` exist.
- [ ] **Step 2: Have Brandon do the user steps.**
  - Install the Claude GitHub App on `hyperformant` ("All repositories").
  - In his own terminal (not through Claude), run `claude setup-token` and the token-file line.
  - Activate mise in the shell.
- [ ] **Step 3: Create the sandbox.** Create a private sandbox repo with `gh repo create`, containing:
  - a small JS project (`package.json` with a `dupes` script that echoes and exits 0)
  - one shell script
  - `.github/devagents.yml` with `jobs: {smoke: {triggers: [manual, pr]}}`
- [ ] **Step 4: Subscribe the sandbox.** Run `/devagents:subscribe <the sandbox repo> --hooks`. Expected: one PR containing the stub, `lefthook.yml` and `prepare`; the secret is present. Merge it, then re-run: expected `already subscribed`.
- [ ] **Step 5: Dispatch `smoke`.** Expected: the run succeeds, and the log shows:
  - the Claude App token obtained
  - the model `fable`
  - the `devagents` skills listed
  - `--max-turns` accepted

  If the OIDC exchange fails, switch to the fallback (a custom App token passed as `github_token`) and record it in the spec.
- [ ] **Step 6: Open a same-repo PR.** Expected: smoke runs in `pr` mode. Then open a fork PR. Expected: the plan job is skipped.
- [ ] **Step 7: Check the hooks in a sandbox clone.**
  - SC2086 script: blocked.
  - `CI=1`: passes.
  - Push: `dupes` runs.
  - Offline, with the cache cleared: the commit proceeds with a warning.
- [ ] **Step 8: Record the results.** Add a "Verified" note to the spec, then commit and push.
- [ ] **Step 9: Save a memory pointer** (`project` type) to `hyperformant/devagents`.
