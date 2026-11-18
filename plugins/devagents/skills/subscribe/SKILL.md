---
name: subscribe
description: Use when subscribing a repository to hyperformant/devagents scheduled jobs or local quick-check git hooks, or repairing an existing subscription.
---

# Subscribe a repo to devagents

Run the script. It checks gh auth and the Claude GitHub App, makes sure the
`CLAUDE_CODE_OAUTH_TOKEN` secret exists, shallow-clones the repo, adds the
Actions stub, and opens (or updates) one PR. Re-running is safe.

```bash
bash <skill base dir>/../../scripts/subscribe.sh <owner/repo> [--hooks] [--dry-run]
```

`<skill base dir>` is the directory of this skill (the base directory shown when
it loaded). Pass `--hooks` when the user also wants the local quick-check git hooks
(lefthook). Pass `--dry-run` to preview the diff with no writes.

## Output and exit codes

Relay the script's output to the user, including any `NOTE:` lines (for example the
migration note when the repo already has husky, pre-commit or `core.hooksPath` hooks).

| Exit | Meaning | What to do |
|------|---------|------------|
| 0 | Done, or `already subscribed` | Report the PR URL or that nothing changed |
| 2 | A Claude token is needed | Relay the printed terminal instructions verbatim, then stop |
| 1 | Error | Show the message; do not retry blindly |

On exit 2 the script prints exactly these lines. Give them to the user verbatim:

```
In your own terminal (not through Claude), run:
  claude setup-token
  mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token
Then re-run the subscribe command.
```

Never suggest running them through Claude's `!` prefix: `read -rs` needs a real
terminal, and `claude setup-token` prints the token, which would land in this
session's transcript.

With `--hooks`, tell the user to run `lefthook install` in their clone after the PR is
merged and pulled (the script only arms a local clone that already has a lefthook config).

## Never

- Never ask for the token in chat, and never accept one pasted there.
- Never put a token in a command line, a file in the repo, or your own output.
- Do not run `gh` or `git` by hand to subscribe; the script is the only path.
