# devagents

Skills, quick git hooks and scheduled AI jobs that repos subscribe to. Two tiers:

| Tier | Where | When | What |
|---|---|---|---|
| 1. Quick checks | local git hooks (lefthook) | pre-commit / pre-push | shellcheck, actionlint, hadolint, your `dupes` / `unused` scripts. They look at one commit's change. |
| 2. Long jobs | GitHub Actions in each subscribed repo | on a schedule, on PR open, or on demand | AI jobs that need the whole codebase. Planned: `codebase-audit` and `test-compactor` (not shipped yet; today only a `smoke` job exists). |

Hooks can be skipped with `--no-verify`, so your repo's own CI stays the merge gate. devagents adds no per-PR gates.

## One-time machine setup

1. Install [mise](https://mise.jdx.dev).
2. Install the tools the hooks use:

       mise use -g lefthook shellcheck actionlint hadolint gh jq yq

   For JS/TS repos, also install `nr` (it uses your existing Node):

       mise use -g npm:@antfu/ni

3. Activate mise in your shell, and put its shims on PATH for git hooks and IDEs:

       # ~/.bashrc
       eval "$(mise activate bash)"
       # ~/.profile
       export PATH="$HOME/.local/share/mise/shims:$PATH"

4. Install the plugin:

       claude plugin marketplace add hyperformant/devagents && claude plugin install devagents@devagents

## One-time GitHub setup

1. Install the Claude GitHub App: <https://github.com/apps/claude>
2. Run these in your own terminal. Never run them through Claude's `!` prefix, because the token would enter the chat:

       claude setup-token
       mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token

`/devagents:subscribe` reads the token file and sets the `CLAUDE_CODE_OAUTH_TOKEN` secret for you.

## Daily use

| Task | What you do |
|---|---|
| Subscribe a repo | `/devagents:subscribe owner/repo`, then merge the PR it opens |
| Add the local quick checks | `/devagents:subscribe owner/repo --hooks` (same PR adds the lefthook remote; it arms the hooks in your clone only when the clone already has a lefthook config, otherwise run `lefthook install` after merging) |
| Expose scanners | `dupes` / `unused` scripts in `package.json`. A `commands:` map in `.github/devagents.yml` is planned, not shipped yet |
| Tune or skip a job for one repo | `.github/devagents.yml` in that repo |
| Run a job now | repo Actions tab, "devagents", Run workflow, set `job` |
| Unsubscribe | delete `.github/workflows/devagents.yml`; remove the devagents `remotes` entry from your lefthook config and the `lefthook install` that `--hooks` added to `prepare` in `package.json`; optionally delete the `CLAUDE_CODE_OAUTH_TOKEN` secret (`gh secret delete CLAUDE_CODE_OAUTH_TOKEN --repo owner/repo`) |

Hooks never block on infrastructure. A set `$CI`, a missing tool or an unreachable remote skips the work and exits 0.

## Overriding a shared hook job

The shared jobs are named `devagents-shellcheck`, `devagents-actionlint`, `devagents-hadolint`, `devagents-dupes` and `devagents-unused`. To change or disable one for yourself, redefine that name in an untracked `lefthook-local.yml`:

    pre-commit:
      jobs:
        - name: devagents-shellcheck
          skip: true

## Releases

Maintainers run the `release` workflow with a version such as `1.2.3`. It runs only from `main`, requires a green `ci` run on `main`'s head, creates the GitHub release, and moves the `v1` tag that hooks pin (1.x versions only).
