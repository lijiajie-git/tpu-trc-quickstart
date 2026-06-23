# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/).
This repo contains **time-sensitive assertions** (command matrix / runtime versions / quotaId / verbatim error text) that drift with GCP behavior;
each entry is tagged with a verification date.

## [Unreleased]

### Added (2026-06-14, verified from a real 16-host training run)

- SKILL §7.5 adds a **multi-host pitfall pointer for the training run period** (pointer only, no training implementation): shutdown barrier hang on exit
  (`jax.distributed.shutdown()` vs `os._exit`+flush trade-off) / mid-run synchronized ckpt write → collective desync core-halt
  (correct fix is **Orbax async checkpoint**; our "write only at the final step" is a workaround).
- SKILL §8.5 + error-map §4 adds the **real situation of the spot preemption window**: only ~30s, the `--autocheckpoint` 5min grace period applies only to
  maintenance, not to spot; don't bet on saving during preemption — flush to GCS/scp as soon as each work unit completes. Honestly annotated GCS=official landing point / scp-local=unofficial but preemption-robust.

## [1.0] — 2026-06-11

First public release.

### Features

- Full AI-driven workflow (SKILL.md): TRC email parsing → quota table → network pre-check → queue → SSH → health check → cleanup (provision-only; you install your own deps)
- conf-driven daemon: multi-zone fanout + claim + cancel loser + FAILED three-way classification + cross-platform notification
- Security: assert_owned (conf allowlist, refuse to start on empty/`*`) + optional job health probe + marker invalidation check
- **Automatic incident logging**: capacity/quota/billing/spot-preemption + claim, written to `TPU_INCIDENT_LOG`;
  `scripts/tpu_stats.sh` aggregates into a TRC-ready summary (for TRC feedback)
- On claim, immediately writes the SSH command to `/tmp/tpu_ssh_cmd.txt` (for the AI to paste into the dialog box)

### Verified environment

- gcloud SDK **562.0.0** (`alpha` + `beta` components)
- Field-tested project: one real TRC project (v5e-64 SPOT @ europe-west4-b / us-central1-a)

### Verified (last-verified 2026-06-11)

- runtime versions: v4=`tpu-ubuntu2204-base` / v5e=`v2-alpha-tpuv5-lite` / v6e=`v2-alpha-tpuv6e`
  (note: the `versions list` listing is **incomplete** — `v2-alpha-tpuv5-lite` is not in the list but can be created in practice)
- spot flag: `--provisioning-model=SPOT` is universal across versions; `--spot` is available in 562.0.0 (older versions error out)
- quota pre-check: `gcloud beta quotas info describe TPUV5sPreemptibleLitepodPerProjectPerZoneForTPUAPI`
  returns per-zone quota; `details: {}` = not granted
- external IP quota defaults to 8; v5e-64/v6e-64 (16 host) must use `--internal-ips`
- FAILED three-way classification field-tested: `code: 8 no more capacity` = capacity class (should re-queue)

### Known to drift (re-verify when used)

- runtime version numbers (check cloud.google.com/tpu/docs/runtimes)
- quotaId naming (beta interface; older SDKs may not recognize it → switch to `gcloud beta quotas info list`)
- per-zone TPU capacity (spot fluctuates in real time)
