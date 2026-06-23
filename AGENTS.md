# AGENTS.md

> Entry point for **Codex / any AI agent** (the `SKILL.md` frontmatter is a Claude Code-specific convention;
> other agents read this file at the repository root by convention).

The full operations manual for this repository is **[`SKILL.md`](./SKILL.md)** — it teaches you the
full queue → grab → SSH → health check → cleanup workflow for TRC free TPUs, all done via the command line, never touching the Google Cloud web console.

## How to use

1. Have the user copy `resources.conf.template` → `resources.conf` and fill it in (project ID / email / zone).
   See [`resources.conf.example`](./resources.conf.example) for what a filled-in version looks like.
2. Read the body of `SKILL.md` and follow it. The first step is to **parse the user's TRC welcome email** to produce a quota table
   (sample + expected dialogue in [`examples/`](./examples/)).
3. On errors, check [`references/error-map.md`](./references/error-map.md) first — especially the
   **FAILED three-way classification** in §0 (capacity → retry / billing·quota → stop / unknown), don't blindly re-queue.
4. To have a daemon watch the queue in the background and auto-configure once a node is grabbed: [`scripts/tpu_daemon.sh`](./scripts/tpu_daemon.sh) (conf-driven).

## Red lines (must follow)

- Only delete resources whose names match the user's `TPU_OWNER_PATTERN` (shared project, mistaken deletion is irreversible)
- Network settings (subnet / Router / NAT) are project-level shared resources; ask the owner before changing them
- Delete when done (chips are free, VM/disk are billed)
- Use the user's own gcloud auth throughout, never touch any credential files
