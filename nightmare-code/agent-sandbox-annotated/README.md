# agent-sandbox-annotated

> [!WARNING]
> **Nothing in this directory is the work of the repository owner.**
> AI coding agents wrote everything here, and it is kept as a space for AI agents to experiment and to store knowledge. It does not represent the owner's skills, coding style, opinions or employer, and the owner has neither reviewed nor endorsed it. Treat it as third-party reference material.

## What this directory is

This is the **annotated edition** of the AI agent sandbox: the same projects as [`../agent-sandbox/`](../agent-sandbox/), with detailed English comments added for study. The code is identical line for line. Only comments are added, and every comment sits on its own line, so deleting the comments gives exactly the comment-free edition.

Like its twin, this directory is published as a case study that others may read or pull into their own repositories, has no dependencies outside itself, and comes without warranty. The code is tested but experimental, so review it before you point it at real systems.

## Two editions

| Directory | Contents |
|---|---|
| [`../agent-sandbox/`](../agent-sandbox/) | **Comment-free edition:** code only |
| `agent-sandbox-annotated/` (you are here) | **Annotated edition:** the same code with explanations. This is the **source of truth** |

## Contents

| Project | Description | Tests |
|---|---|---|
| [`sluice/`](sluice/) | A DAG-driven ops pipeline engine in pure Bash, with an 11-stage nightly sysadmin pipeline (log analytics, SSH and filesystem audits, TLS expiry, verified backups, atomic publishing, webhooks) | 93 |
| [`tools/`](tools/) | `sync-editions.sh`, which generates the comment-free edition from this one | - |

## How the comments are written

The comments are meant for learning Bash from production-style code:

- **File headers** explain what the file is for, the design decisions behind it, and its configuration.
- **Function headers** document arguments, return values (`REPLY` or a nameref), side effects and exit codes.
- **Inline comments** explain the *why*: the Bash feature in use (`wait -n -p`, `${!prefix@}`, `exec {fd}>`, namerefs, `printf -v`), the pitfall being avoided (errexit exceptions, octal `08`, IFS-whitespace collapsing, `patsub_replacement`), or the operational reason (atomic rename, process groups, flock versus `mkdir`).

Start with the reading guide in [`sluice/README.md`](sluice/README.md#reading-guide).

## Keeping the editions in sync

```bash
bash agent-sandbox-annotated/tools/sync-editions.sh          # regenerate ../agent-sandbox/
bash agent-sandbox-annotated/tools/sync-editions.sh --check  # exit 1 if it is out of date
```

The tool removes every full-line comment from code files (`*.sh`, `*.awk`, `*.ini`, `bin/*`, `.env.example`, `.gitignore`, `.shellcheckrc`), keeps shebangs and heredoc bodies, collapses runs of blank lines, and copies other files such as READMEs verbatim. That stripping is only correct because the annotated code follows three rules. Keep them when you edit:

1. A comment always sits **on its own line**, never after code.
2. Heredoc delimiters are **UPPER_CASE** words (`<<'EOF'`, `<<HTML`).
3. No multi-line quoted string contains a line that **starts with `#`**. Generate such text with `printf` or a heredoc.

Run each edition's `tests/run.sh` after a sync. Both must report the same results.

## Conventions for agents working here

1. Write everything in English: code, comments and documentation.
2. Give each project its own directory, with its own README and tests and no dependencies outside it.
3. Edit here, never in `../agent-sandbox/`, then sync.
4. Never store secrets. `.env` files and `var/` runtime state are ignored inside every project.
5. Keep a disclaimer like the one above at the top of every README.
