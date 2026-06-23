# Example: Ideal Conversation Transcript

> An ideal AI to-do flow from zero to chips-visible, to align the agent on expected behavior. Commands are real;
> outputs are abbreviated.

---

**User**: I got my TRC quota, help me set up a TPU. [pastes TRC email + filled-out resources.conf]

**AI**:
1. Parse the email → quota table (see `examples/trc-email-and-quota-table.md`). You have v5e-64 in two zones (spot) + v4-32 (on-demand).
2. preflight: confirm `gcloud auth list` active account = your email, `gcloud config` project is correct.
3. Environment: `gcloud components install alpha beta` (needed for queuing + quota queries).
4. Network preflight (v5e-64 is 16 hosts): check IP quota = 8 < 16 → must use `--internal-ips`; confirm the region has Private Google Access + Cloud NAT enabled (for a shared project, ask the owner first).
5. Check quota before queuing:

```
$ gcloud beta quotas info describe TPUV5sPreemptibleLitepodPerProjectPerZoneForTPUAPI \
    --service=tpu.googleapis.com --project=example-proj --format="yaml(dimensionsInfos)"
  europe-west4-b: value '64'   us-central1-a: value '64'   # both zones have quota
```

6. **Dual-zone fanout** queues two v5e-64 SPOT requests (each with `--internal-ips`).
7. Poll. eu-b stays in PROVISIONING ~10min (normal, don't delete); us-a reports `code: 8 no more capacity` →
   **three-way classification identifies capacity** (not billing/quota) → delete + re-queue, don't stop.
8. eu-b turns `READY`. health = `HEALTHY`, worker 0 SSH succeeds → claim, **immediately cancel the loser QR for us-a**.
9. **Health check (no dependency install)**: `--worker=all --batch-size=8` confirms all 16 hosts SSH, chips present (`/dev/vfio*` on v5e, `/dev/accel*` on v4), and PyPI reachable (NAT OK). **This skill installs nothing** — what to install is the user's call.

```
$ ... --worker=all --batch-size=8 --command='echo HC_OK; ls -d /dev/vfio* /dev/accel* >/dev/null 2>&1 && echo CHIP_OK; python3 -c "import urllib.request as r; r.urlopen(\"https://pypi.org\",timeout=10); print(\"PYPI_OK\")"'
  16/16 HC_OK · CHIP_OK · PYPI_OK
```
   ⚠️ Do **not** verify chips with `python3 -c 'import jax; print(jax.device_count())'` from a single SSH — any device op triggers multi-host backend init and a single process hangs >60s waiting for the other hosts. Chip visibility is confirmed only when your real job calls `jax.distributed.initialize()` on all hosts at once (see SKILL §7.5).

**AI**: Claimed `tpu-v5e-64-vm-me-eu-b @ europe-west4-b`. Health check passed (16/16 SSH, chips present, NAT OK); **nothing installed**.
SSH: `gcloud alpha compute tpus tpu-vm ssh tpu-v5e-64-vm-me-eu-b --zone=europe-west4-b --worker=0 --tunnel-through-iap`.
Now install your own deps (e.g. `pip install -r requirements.txt`). Remember to delete when done (chips are free, the VM is billed).

---

Key correct behaviors: **preflight first / dual-zone fanout / FAILED three-way classification (re-queue on capacity rather than stop) / cancel the loser once claimed / dual liveness probe via health + SSH / provision-only health check (install nothing) / never `device_count` from a single SSH (multi-host hang) / reminder to delete when done**.
