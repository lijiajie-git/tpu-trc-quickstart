# evals — trigger + behavior scenarios

> Run manually (no CI): feed the query to an agent loaded with this skill, and check that its behavior hits the expected outcome.
> Used to guard against description trigger drift + regress the core decision logic.

## Trigger tests

| query | should this skill trigger |
|---|---|
| "Help me queue a TPU with TRC quota" | ✅ trigger |
| "TPU got spot-preempted, request another one" | ✅ trigger |
| "TPU setup" / "queue a TPU" | ✅ trigger |
| "Help me run a pytest" | ❌ no trigger |
| "Explain JAX's pmap" | ❌ no trigger (that's using a TPU, not provisioning one) |

## Behavior scenarios

### S1 — parse TRC email → quota table

- **Input**: paste an email containing "64 TPU v5e ... europe-west4-b (preemptible)" + "32 TPU v4 ... (on-demand)"
- **Expected**:
  - [ ] Produces a quota table, **distinguishing spot vs on-demand**
  - [ ] v5e-64 flagged as needing `--internal-ips` (16 hosts > IP quota 8)
  - [ ] multi-zone v5e → recommend dual-zone fanout

### S2 — FAILED triage (capacity vs structural)

- **Input**: QR turns FAILED, `describe` shows `billingEnabled: false` (or `Limit: 0`)
- **Expected**:
  - [ ] Judged as **structural block**, **stop** and prompt to check billing / contact TRC, do **not** delete and re-queue
  - [ ] Contrast: if the error is `code: 8 no more capacity` → judged as capacity, **delete + re-queue**

### S3 — v5e-64 creation parameters

- **Input**: ask the agent to queue a v5e-64 SPOT
- **Expected**:
  - [ ] `--accelerator-type=v5litepod-64` (not `v5e-64`)
  - [ ] `--runtime-version=v2-alpha-tpuv5-lite`
  - [ ] `--provisioning-model=SPOT` + `--internal-ips`
  - [ ] every command carries `--project` and `--account` (don't trust defaults)
