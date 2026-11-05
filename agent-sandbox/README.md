# agent-sandbox

> [!WARNING]
> **Nothing in this directory is the work of the repository owner.**
> AI coding agents wrote everything here, and it is kept as a space for AI agents to experiment and to store knowledge. It does not represent the owner's skills, coding style, opinions or employer, and the owner has neither reviewed nor endorsed it. Treat it as third-party reference material.

## What this directory is

`agent-sandbox/` is a workspace set aside for AI agents:

- **Experiments:** complete, runnable projects built to explore an idea or a technique.
- **Knowledge:** reference implementations and worked examples kept for later study.

It is deliberately isolated from the rest of the repository:

- **Published as a case study.** It is committed so others can read it or pull it into their own repositories, but it is not part of the owner's own work in this repository.
- **Self-contained.** Nothing outside this directory depends on it, and every project runs from its own folder.
- **No warranty.** The code is tested but experimental. Review it before you point it at real systems.

## Two editions

| Directory | Contents |
|---|---|
| `agent-sandbox/` (you are here) | **Comment-free edition:** code only |
| [`../agent-sandbox-annotated/`](../agent-sandbox-annotated/) | **Annotated edition:** the same code, line for line, with detailed English comments for learning |

This edition is **generated**, so do not edit it by hand. Make changes in the annotated edition, then regenerate this one:

```bash
bash agent-sandbox-annotated/tools/sync-editions.sh          # rewrite this edition
bash agent-sandbox-annotated/tools/sync-editions.sh --check  # verify both editions match
```

## Contents

| Project | Description | Tests |
|---|---|---|
| [`sluice/`](sluice/) | A DAG-driven ops pipeline engine in pure Bash, with an 11-stage nightly sysadmin pipeline (log analytics, SSH and filesystem audits, TLS expiry, verified backups, atomic publishing, webhooks) | 93 |

## Conventions for agents working here

1. Write everything in English: code, comments and documentation.
2. Give each project its own directory, with its own README and tests and no dependencies outside it.
3. Treat the annotated edition as the source of truth, and regenerate this edition with the sync tool.
4. Never store secrets. `.env` files and `var/` runtime state are ignored inside every project.
5. Keep a disclaimer like the one above at the top of every README.
