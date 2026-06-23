# tpu-trc-quickstart

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

> After you receive a free TPU quota from Google **TRC (TPU Research Cloud)**, hand the entire
> "queue → claim → connect → run" flow to an AI (Claude Code / Codex / any LLM agent) to handle
> on the command line, **without ever touching the Google Cloud web console**.
> 
> All commands, state machines, and pitfalls have been hit and field-tested in advance (GCP TPU spot/preemptible scenarios). Primarily in English prose, with English commands.
> 
> As far as I know, the public ecosystem **has not yet seen a comparable TPU/TRC claim agent skill**.

> **This repo = one skill**. The GitHub repo is named `tpu-trc-quickstart`, but the mount/install name is
> **`tpu-trc-setup`** (= the `name` in the `SKILL.md` frontmatter). Claude Code users place it under
> `~/.claude/skills/tpu-trc-setup/`.

---

## What this is

TRC grants a **command-line quota**, but the official docs are scattered and full of gotchas (IP quota, IAP tunnel, spot preemption, PROVISIONING hangs, etc.).
This repo solidifies the whole flow into an **AI work instruction sheet** + a **claim daemon script**:

- `SKILL.md` — the complete instruction sheet for the AI (parse TRC email → build quota table → network preflight → queue → SSH → **health check** → cleanup). **This repo only delivers a usable bare node; it installs no dependencies for you (not even jax)** — install whatever you need yourself (SSH in, or let the AI install per `requirements.txt`); pitfalls and reasons in `SKILL.md` §7
- `scripts/tpu_daemon.sh` — background daemon: polls the queue, claims as soon as one is available, auto-cancels surplus requests, smart triage on FAILED
- `resources.conf.template` / `resources.conf.example` — fill in your project/account/zone; both the daemon and the AI read it
- `scripts/trc_biweekly_report.sh` — turns the incident log into a feedback email **sent to TRC automatically every two weeks** (optional routine, see "Feedback to TRC" below)
- `references/error-map.md` — full table of error → root cause → handling (capacity / quota / billing three-way classification)
- `examples/` — redacted TRC email + expected quota table + ideal conversation trace (for AI alignment)
- `AGENTS.md` — entry point for Codex / other agents (points to `SKILL.md`)
- `scripts/tpu_stats.sh` — aggregates the incident log into a summary you can paste to TRC (see "Feedback to TRC" below)

## Three-step getting started

1. **Fill the config**: copy `resources.conf.template` → `resources.conf`, fill in your project ID, email, zone.
2. **Hand it to the AI**:
   - Claude Code: drop the whole folder into `~/.claude/skills/tpu-trc-setup/` and say "TRC TPU setup" in the conversation.
   - Codex / others: paste the full `SKILL.md` into the conversation + paste your TRC welcome email, and say "set up a TPU for me following this".
3. **Wait for the claim**: the AI runs through queue → claim → SSH → health check (chips visible + NAT reachable) → delivers a bare node. **You install dependencies yourself** (SSH in, or let the AI install per `requirements.txt`). Optionally use `scripts/tpu_daemon.sh` to auto-watch in the background.

## Red lines

- Only delete resources **you created yourself** (the project may be shared; deleting someone else's = deleting someone else's experiment)
- Network settings (subnet / Router / NAT) are project-level shared resources; ask the project owner before changing them
- **Delete when done** — TPU chips are free but VM/disk are billed by the hour
- Use your own Google account throughout; do not ask anyone for passwords/private keys/service account keys

> Security: this tool **stores no credentials**; all commands go through your local `gcloud auth`. The
> `resources.conf` you fill in (containing project ID/email) is already in `.gitignore` and will not be committed.

## Scope of applicability

- TPU types: v2-8 / v3-8 / v4-32 / v5e-64 / v6e-64 (command matrix in `SKILL.md` §5)
- Platforms: macOS / Linux (the daemon uses bash, compatible with macOS's built-in bash 3.2)
- Contains no code/data from any specific project; no file edits needed beyond `resources.conf`

## Limitations and boundaries

This repo only does the **"after you get the TRC quota, claim + set up + connect to one machine"** preliminary step. It does **not** do:

- Training checkpoint / resume — that's your training script's job (write to GCS, see `SKILL.md` §8.5)
- Auto-resume training after spot preemption — the daemon only claims the machine back; resuming relies on your ckpt recovery
- Multi-region / multi-cloud failover, K8s/Ray orchestration — for industrial-grade, use [SkyPilot](https://github.com/skypilot-org/skypilot) / [Levanter](https://github.com/stanford-crfm/levanter)

Tribute to prior work in the same direction: [tpu-starter](https://github.com/ayaka14732/tpu-starter) (a human-readable knowledge base),
[tpunicorn](https://github.com/shawwn/tpunicorn) (`pu babysit`, the origin of the babysit concept, old tpu create API),
[tpucare](https://github.com/ClashLuke/tpucare) (event-driven setup-hook, same idea as our conf's `TPU_SETUP_CMD`).
Difference: this repo is **AI-delegated + queued-resources (v5e/v6e) + FAILED three-way classification** — none of the old tools cover this new path.

## Stopping the daemon / cleaning up resources

While the daemon is still alive, deleting the QR directly will make it **automatically re-queue the QR** (the health check sees MISSING→recreate).
You must **kill the daemon first, then delete**:

```bash
touch /tmp/tpu_daemon.stop          # daemon exits on its next loop when it sees this, no more recreate
pkill -9 -f '[t]pu_daemon\.sh'      # actually kill. ★ bracket is required: `pkill -f tpu_daemon.sh` would match
                                    #   the command's own shell (cmdline contains the literal string) → kills itself, misses the real daemon
pgrep -f '[t]pu_daemon\.sh'         # confirm empty before deleting the QR (bracket, otherwise a permanent false positive "still there")
# ... delete your QR ...            # rescan after deleting to confirm resources are empty + nothing revived
rm -f /tmp/tpu_daemon.stop          # clear it so the next start works normally
```

## Feedback to TRC (automatic incident logging)

On every queue anomaly (capacity stockout / quota not granted / billing block / spot preemption) + every successful claim,
the daemon automatically appends a line (including handling) to the `TPU_INCIDENT_LOG` in `resources.conf` (default `~/.tpu_trc_incidents.tsv`).

```bash
./scripts/tpu_stats.sh        # aggregate into a summary you can paste straight to TRC
```

Example output:

```
=== TPU TRC incident summary (this machine) ===
range: 2026-06-01  ~  2026-06-11
total records: 24  | CLAIMED successfully: 7  | project-level blocks: 0

by category:
  capacity-stockout      12
  spot-preemption         5
  quota-not-granted        0

capacity stockout by zone (TRC cares most — which zone has no capacity):
  europe-west4-b         8 times
  us-central1-a          4 times
```

This helps you fulfill the TRC "publicly share your usage experience" obligation, and helps TRC see which zones have capacity/quota issues.
Don't want logging: set `TPU_INCIDENT_LOG=""` in `resources.conf`.

### Biweekly automatic feedback (optional routine)

Turn the above summary into something **sent to TRC automatically every two weeks**, so you don't have to remember to send it manually:

```bash
# Generate the report (if the machine has mail/msmtp and TRC_EMAIL is set, it sends directly; otherwise saved to a file for manual pasting)
TRC_EMAIL=trc-support@google.com ./scripts/trc_biweekly_report.sh

# Set it on a schedule: cron runs at 09:00 on the 1st / 15th each month (≈ biweekly; cron has no native biweekly)
crontab -e    # add one line:
# 0 9 1,15 * * cd /path/to/tpu-trc-quickstart && TRC_EMAIL=trc-support@google.com ./scripts/trc_biweekly_report.sh
```

- If it can't send (no MTA configured on the machine) → the script saves the body to `~/.tpu_trc_report_<date>.txt`; paste it manually into an email to `trc-support@google.com` (or Discord `#tpu-research-cloud`).
- An empty report when there are no incidents is normal — it at least proves you're using it and capacity had no stockouts.

## Provenance

This skill was distilled from several months of TPU practice across multiple efforts, rather than from a single lucky run: it started with my own tinkering on ft-transformer training and on a benchmark selection comparison, where I began recording pitfalls; it was later validated and filled out extensively in a research project porting an agent-based simulator from MATLAB to JAX/TPU, and finally solidified into the present work instruction sheet. This repo contains no code or data from any of the above projects. All pitfalls were obtained from real runs; errors in `error-map.md` such as `code:8 no more capacity` are real verbatim text. Thanks to Bruce Alan Wilcox for bringing me into this TPU project, and thanks to Edgar Chen and the Google TPU Research Cloud (TRC) team for providing compute support.

> Research supported with Cloud TPUs from Google's TPU Research Cloud (TRC).

All pitfalls were obtained from real runs; entries in `error-map.md` such as `code:8 no more capacity` are real verbatim error text.

## License

MIT
