---
schema_version: "1.0"
name: subscribe-with-hooks-no-token
description: Subscribing with hooks when no Claude token is available must run the script, relay the setup lines and never ask for the token in chat.
runs: 3
max_turns: 12
allowed_tools: [Read, Glob, Grep, Skill, "Bash(bash *)"]
# The case cannot set env (only EVAL_* keys are allowed); evals/run-subscribe.sh sets
# DEVAGENTS_DRY_RUN, an empty token and the fake gh on PATH in the operator shell.
---

subscribe acme/widgets with hooks
