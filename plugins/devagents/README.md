# devagents plugin

The Claude Code plugin half of [hyperformant/devagents](https://github.com/hyperformant/devagents). It contains:

- **`subscribe` skill** (`/devagents:subscribe owner/repo [--hooks] [--dry-run]`): subscribes a repo by opening a PR with the workflow stub, and with `--hooks` wires the shared lefthook remote.
- **Bot rules** (`bot-rules.md`): the system-prompt rules the scheduled jobs run under.
- **Scripts** (`scripts/`): `subscribe.sh` (used by the skill) and `plan-due.sh` (used by the reusable workflow).

Install it from the marketplace:

    claude plugin marketplace add hyperformant/devagents && claude plugin install devagents@devagents

See the [root README](../../README.md) for setup and daily use.
