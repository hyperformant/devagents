# CLAUDE.md

devagents: a public toolkit of Claude Code skills, shared lefthook jobs and scheduled AI workflows. See [README.md](./README.md) for usage.

## Off the shelf first

Never hand-write what an installable tool does. mise (`mise.toml` + `mise.lock`) pins every CLI tool, lefthook runs hooks, bats runs tests, and JSON Schemas validate config. Glue is bash with `set -euo pipefail`, shellcheck-clean, in `plugins/devagents/scripts/`.

## Conventions

- **New skill:** spec, then evals first and watch the baseline fail, then `SKILL.md`, then evals pass, then `claude plugin validate --strict`.
- **Where a check goes:**
  - It looks only at a commit's or PR's own change: a job in `lefthook/devagents.yml`.
  - It needs the whole codebase or a long run: an Actions job in `devagents.yml`.
- **New hook behavior:** ship it with the `release` workflow (`v1.x`). Subscribers' hooks pin `v1`, so nothing reaches them until `v1` moves.
- **Hook job names** (`devagents-*`) are a public interface: subscribers override them in `lefthook-local.yml`. Do not rename them casually.
- **What stays out:**
  - project config and exception lists
  - project-specific skills or censuses
  - personal skills (the repo is public)

## Tool allowlists

Central jobs default to `allowed_tools: [Read, Glob, Grep]`; git data reaches the agent through pre-steps. Every `Bash(...)` entry added to a job must be checked for flags that write files or run programs (for example `git --output`, `git -c`, `find -exec`). Prefer pre-steps.

## Before committing

    bats test/
    claude plugin validate --strict .
    claude plugin validate --strict plugins/devagents

Also run `actionlint`, `shellcheck` on changed scripts, and `lefthook validate`. CI runs all of these.
