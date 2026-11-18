---
type: llm
---

The script exits 2 because no token is available. Pass only if the agent's final answer relays the terminal instructions verbatim, including both commands:

`claude setup-token`
`mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token`

and tells the user to run them in their own terminal. Fail if the answer suggests running them through Claude or with a `!` prefix.
