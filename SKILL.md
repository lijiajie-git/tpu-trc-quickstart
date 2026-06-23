---
name: tpu-trc-setup
description: 'End-to-end workflow to go from zero to running on a free TRC TPU (delegated to AI). Triggers: "TRC TPU setup", "queue a TPU", "set up a TPU with TRC quota", "TPU setup". Works for anyone who has obtained a TPU Research Cloud quota — hand this file to Claude Code / Codex / any AI and it can run the whole thing from the command line, no need to touch the Google Cloud web console.'
license: MIT
compatibility: Requires gcloud (with alpha + beta components) + macOS/Linux bash + a GCP project that has been granted a TRC quota (Editor role is enough)
metadata:
  version: "1.0"
  last-verified: "2026-06-11 / gcloud SDK 562.0.0 (alpha+beta)"
---

# TRC TPU all-in-one (AI-delegated edition)

> `last-verified: 2026-06-11` (the command matrix / runtime versions / quotaId drift with GCP; check the verification date here + CHANGELOG.md)

> **What this is**: you just received a free TPU quota from Google TRC (TPU Research Cloud),
> and you want to skip the Google Cloud web console and docs and let an AI claim, connect to, and run the TPU for you straight from the command line.
> This file is the complete instruction sheet for the AI — every pitfall has been field-tested in advance.
> 
> **How to use it**:
> 
> - **Claude Code users**: drop this folder into `~/.claude/skills/tpu-trc-setup/` and say "TRC TPU setup" in the conversation to trigger it
> - **Codex / other AIs**: paste the full text of this file into the conversation, or put it in a repo for the AI to read, then say "set up the TPU for me following this"
> 
> **Red lines (both AI and humans must obey)**:
> 
> 1. Only delete resources **you created yourself** — the project may be shared, and deleting someone else's TPU means deleting their experiment
> 2. Network settings (subnet / Router / NAT) are project-level shared resources; ask the project owner before changing them
> 3. **Delete when done** — TPU chips are free but the VM/disk is billed by the hour, and an idle node overnight is real money
> 4. Use your own Google account throughout; never ask anyone for a password / private key / service account key

---

## 1. [Fill this in first] Your information

```
My Google account email:  <YOUR_EMAIL>
My GCP project ID:         <YOUR_PROJECT_ID>     # the project the TRC quota was injected into
My role:                   <Owner / Editor>      # Editor is enough
```

**[Paste your TRC approval email below]** (Subject is usually "Welcome to the TPU Research Cloud"):

```
<paste the full TRC email text>
```

**AI step one**: parse the TRC email above and produce a quota table before starting work:

| Field                                   | Where to find it in the email                          |
| --------------------------------------- | ------------------------------------------------------ |
| TPU type (v2/v3/v4/v5e/v6e) + chip count | quota list in the email body                          |
| zone for each quota                     | same place (a quota is **valid only in the named zone**, no swapping) |
| on-demand vs preemptible/spot           | same place (spot can be preempted at any time)         |
| validity period                         | usually 30 days from approval                          |

> TRC obligations: you must publish results publicly (paper / open source / blog post) + give Google feedback on your experience.
> For problems, contact trc-support@google.com or the
> `#tpu-research-cloud` channel on the Google Developer Community Discord.

---

## 2. One-time environment (local machine)

```bash
# 2.1 Install the Google Cloud SDK (skip if already installed): https://cloud.google.com/sdk/docs/install
gcloud version

# 2.2 The TPU queue commands live in the alpha component — must install
gcloud components install alpha

# 2.3 Log in + set the default project
gcloud auth login <YOUR_EMAIL>
gcloud config set project <YOUR_PROJECT_ID>
gcloud auth list                       # confirm the active account is your own
gcloud config get-value project        # confirm the project is correct

# 2.4 (optional) Some Python SDKs need ADC
gcloud auth application-default login
```

**Pitfall: in an AI execution environment `gcloud` is often not on PATH**, throwing `gcloud: command not found`.
Run this line first, and use `$GCLOUD` throughout the rest of the file:

```bash
export GCLOUD=$(which gcloud || echo /opt/homebrew/bin/gcloud)   # common mac homebrew path
```

---

## 3. Pre-work scan (avoid creating duplicates / deleting someone else's)

```bash
# Scan every zone that appears in the TRC email
for zone in <zone1> <zone2> <zone3>; do
  echo "=== $zone ==="
  $GCLOUD alpha compute tpus queued-resources list \
    --project=<YOUR_PROJECT_ID> --zone=$zone \
    --format="table(name, state.state, tpu.nodeSpec[].node.acceleratorType)" 2>/dev/null
done
```

- Already `ACTIVE` → jump straight to §7 and use it, **do not create a new one**
- A resource with someone else's name prefix → leave it alone

---

## 4. Network preflight (only large TPUs with ≥16 hosts need this, e.g. v5e-64 / v6e-64)

**Background**: a GCP project's external IP quota per region defaults to only **8**, while v5e-64 / v6e-64 needs 16 host IPs.
Creating without handling this will fail with `IN_USE_ADDRESSES limit` FAILED. Small TPUs (v4-32 has only 4 hosts / single-host v2-8 v3-8) don't need this section.

```bash
# 4.1 Check the current IP quota (confirm whether the limit is 8)
$GCLOUD compute project-info describe --project=<YOUR_PROJECT_ID> \
  --format="table(quotas.filter(metric:IN_USE_ADDRESSES))"

# 4.2 Fix: create with internal IPs (--internal-ips, see §5), which uses no external IP quota at all.
#     Prerequisite A: the region's default subnet has Private Google Access enabled (to pull libtpu)
$GCLOUD compute networks subnets update default \
  --region=<REGION> --enable-private-ip-google-access --project=<YOUR_PROJECT_ID>

#     Prerequisite B: the region needs a Cloud Router + Cloud NAT (for pip install; PGA does not cover PyPI)
$GCLOUD compute routers create my-tpu-router \
  --network=default --region=<REGION> --project=<YOUR_PROJECT_ID>
$GCLOUD compute routers nats create my-tpu-nat \
  --router=my-tpu-router --region=<REGION> \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges \
  --project=<YOUR_PROJECT_ID>
```

> ⚠️ All three commands in 4.2 are **project-level shared settings**. In a shared project, first ask the owner whether they are already configured (configured once = permanent), and don't recreate them.
> 
> **Hidden symptom of missing NAT**: later when a worker installs dependencies (e.g. jax), pip reports
> `Could not find a version that satisfies the requirement jax[tpu]` but the script may still say "done"
> — this is a silent pip failure, not a version problem; go back and add the NAT.

---

## 5. Create the TPU (queue)

### Command matrix

| TPU    | `--accelerator-type` | `--runtime-version`   | host count | needs `--internal-ips`? |
| ------ | -------------------- | --------------------- | ---------- | ----------------------- |
| v2-8   | `v2-8`               | `tpu-ubuntu2204-base` | 1          | no                      |
| v3-8   | `v3-8`               | `tpu-ubuntu2204-base` | 1          | no                      |
| v4-32  | `v4-32`              | `tpu-ubuntu2204-base` | 4          | no                      |
| v5e-64 | `v5litepod-64`       | `v2-alpha-tpuv5-lite` | 16         | **yes**                 |
| v6e-64 | `v6e-64`             | `v2-alpha-tpuv6e`     | 16         | **yes**                 |

> The runtime-version updates over time. When you hit a version error: first
> check with `$GCLOUD alpha compute tpus versions list --zone=<ZONE>`
> (⚠️ field-tested: the list is **incomplete** — `v2-alpha-tpuv5-lite` may not be in the list but is actually usable; treat the list as reference only),
> and if it still doesn't match, check the official docs (§10).

### Spot (use this for preemptible quota)

```bash
$GCLOUD alpha compute tpus queued-resources create <queue name, e.g. my-v5e-qr> \
  --node-id=<VM_NAME, e.g. my-v5e-vm> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> \
  --accelerator-type=<from table above> \
  --runtime-version=<from table above> \
  --provisioning-model=SPOT \
  --internal-ips          # add only for ≥16-host TPUs such as v5e-64/v6e-64
```

> **Pitfall (version-dependent)**: on older SDKs spot must be written as `--provisioning-model=SPOT`; writing `--spot` / `--best-effort`
> throws `STANDARD provisioning model is incompatible with spot requests`. **On newer SDKs (field-tested on 562.0.0) `--spot`
> works, so either is fine.** When unsure, use `--provisioning-model=SPOT` (recognized by all versions).

### On-demand (use this for non-preemptible quota, most stable)

```bash
$GCLOUD alpha compute tpus queued-resources create <queue name> \
  --node-id=<VM_NAME> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> \
  --accelerator-type=<from table above> \
  --runtime-version=<from table above> \
  --guaranteed
```

### Claiming strategy

- **Cross-zone fanout**: if the same type of quota exists in multiple zones → queue one request in parallel in each zone that **has quota**
  (field-tested: per-zone quotas in different zones are mutually independent and non-exclusive; GCP officially also encourages spreading spot across multiple zones)
- **No duplicate queueing in the same zone**: queuing two requests of the same type in one zone is pointless (same capacity pool, no speedup, and it collides with the same per-zone quota slots)
- **As soon as one is claimed, immediately cancel the remaining losers**: otherwise the losers stay in the cloud and keep queueing, and once one goes ACTIVE the VM starts burning money (free chips ≠ free machine)
- **Confirm the zone has quota before queueing**: a zone with no quota (check quota in §4.5 below) will always FAILED if queued — pure waste
- A zone reporting `no more capacity` → not a command error; switch zones, **do not retry rapidly in the same zone**
- For tight-supply models like v6e, experience says they are "single-slot" (queue one at a time and it fills up) — don't spread them out wide alongside other models at the same time
- After a spot claim, average survival is a few hours → use it as soon as you claim it and back up results promptly

### First check whether a zone has quota (avoid wasted queueing; requires `gcloud components install beta`)

```bash
# v5e preemptible per-zone quota (for other models swap in the matching quotaId, see §10 official docs)
$GCLOUD beta quotas info describe TPUV5sPreemptibleLitepodPerProjectPerZoneForTPUAPI \
  --service=tpu.googleapis.com --project=<YOUR_PROJECT_ID> \
  --format="yaml(quotaId,dimensionsInfos)"
```

Read the per-zone value in `dimensionsInfos`: `'64'` = enough for one 64-chip slice / `'0'` = explicit zero /
**missing (`details: {}`) = that zone was not granted quota**, queuing will always FAILED.
(quotaId is a beta API; the ID can change across SDK versions; if an old version doesn't recognize it, first run `gcloud beta quotas info list` to get the real ID.)

---

## 6. Waiting: the state machine

```bash
# Poll (every 30s is enough, don't poll too often)
$GCLOUD alpha compute tpus queued-resources describe <queue name> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --format="value(state.state)"
```

| State                   | Meaning                              | Deletable? | What to do                                       |
| ----------------------- | ------------------------------------ | ---------- | ------------------------------------------------ |
| `ACCEPTED`              | in the queue                         | ✅          | wait                                             |
| `WAITING_FOR_RESOURCES` | queued for capacity (minutes to hours) | ✅        | wait                                             |
| `PROVISIONING`          | allocating hardware                  | ❌ **can't delete** | wait (**field-tested: can stall 2h+ and still succeed — this is normal**) |
| `ACTIVE`                | ready                                | ✅          | **go to §7 immediately**                         |
| `SUSPENDED`             | spot was preempted                   | ✅          | delete + re-queue (field-tested: waiting for auto-recovery is essentially hopeless) |
| `FAILED`                | creation failed                      | ✅          | **describe first to see the root cause, then decide** (three-way classification below; don't blindly re-queue) |

> **Pitfall**: calling delete in the `PROVISIONING` state throws
> `DeleteQueuedResource is not supported when state is PROVISIONING`; you can only wait for it to become ACTIVE or FAILED.

### FAILED three-way classification (decide "re-queue" vs "stop"; don't blindly re-queue)

`gcloud alpha compute tpus queued-resources describe <QR>` — read the error and sort into three buckets:

| Category               | Criterion (error.message)                                                                                                  | Meaning                          | Action                                            |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------- |
| **capacity** (retry)   | `code: 8` `no more capacity in the zone` / `GCE_STOCKOUT` / `ZONE_RESOURCE_POOL_EXHAUSTED`                                 | quota exists but the zone is out of stock right now | delete + switch/re-queue, hedge with multi-zone fanout |
| **structural** (stop)  | `PERMISSION_DENIED ... billing` / `billingEnabled: false` / `Limit: 0` / `RESOURCE_EXHAUSTED` / `NO_VALID_BILLING_ACCOUNT` | quota not granted / billing off / permission issue | **stop**, don't re-queue (it will never succeed); check billing or contact TRC/owner |
| **unknown**            | anything else                                                                                                              | never seen before                | default to a single capacity re-queue then observe |

> Billing/project self-check commands: `$GCLOUD beta billing projects describe <YOUR_PROJECT_ID>` (look at `billingEnabled`),
> `$GCLOUD projects describe <YOUR_PROJECT_ID>`. `billingEnabled: false` takes down the entire TPU API, even if the quota is still there.

Delete command (use it both before re-queuing and after you're done):

```bash
$GCLOUD alpha compute tpus queued-resources delete <queue name> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --force --quiet
```

Optional: write a 30s polling script that pops a notification when READY (macOS example; the AI can write one for the local OS on the fly):

```bash
while true; do
  S=$($GCLOUD alpha compute tpus tpu-vm describe <VM_NAME> \
      --project=<YOUR_PROJECT_ID> --zone=<ZONE> --format="value(state)" 2>/dev/null)
  [ "$S" = "READY" ] && { echo "claimed it!"; break; }
  sleep 30
done
```

> In a long loop gcloud can lose its login state ("to select an already authenticated account").
> **Add `--account=<YOUR_EMAIL>` to every gcloud command**, and as a fallback put
> `export CLOUDSDK_CORE_ACCOUNT=<YOUR_EMAIL>` at the top of the loop.
> Also: macOS has no `timeout` command; for an SSH time limit use `--ssh-flag="-o ConnectTimeout=15"`.

---

## 7. SSH + health check + install **your own** dependencies

> **This repo only delivers "a working bare node" — it installs no dependencies for you (not even jax).** Reasons: ① each task has different dependencies,
> a template can't guess right; ② preinstalling a generic jax may conflict with the version you pinned; ③ **spot preemption is unrelated to whether the machine is busy or idle — preinstalling doesn't prevent
> preemption**, and it slows down what actually matters (launching the job ASAP + checkpointing). Whatever you need, SSH in and install it yourself, or let your
> AI install per `requirements.txt`; for automation see `TPU_SETUP_CMD` at the end of §7.4.

```bash
# 7.1 First confirm the worker count (don't go by memory; v5e-64=16, v6e-64=16, v4-32=4, v3-8/v2-8=1)
$GCLOUD alpha compute tpus tpu-vm describe <VM_NAME> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> \
  --format="value(networkEndpoints[].ipAddress)" | wc -l

# 7.2 SSH into worker 0 (first time auto-generates ~/.ssh/google_compute_engine key — it's yours)
$GCLOUD alpha compute tpus tpu-vm ssh <VM_NAME> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --worker=0 --tunnel-through-iap

# 7.3 Health check (confirm the machine works, install nothing): all workers SSH-reachable + chips present + NAT reachable
#     v5e chips are at /dev/vfio*, v4 at /dev/accel*; PyPI reachable = NAT works (otherwise pip will silently fail later)
$GCLOUD alpha compute tpus tpu-vm ssh <VM_NAME> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --worker=all --batch-size=8 --tunnel-through-iap \
  --command='echo SSH_OK; ls -d /dev/vfio* /dev/accel* 2>/dev/null | head -1; python3 -c "import urllib.request as r; r.urlopen(\"https://pypi.org\",timeout=10); print(\"PYPI_OK\")"'

# 7.4 Install **your own** dependencies (this repo won't do it for you). Most TPU tasks need JAX; this libtpu URL installs it:
$GCLOUD alpha compute tpus tpu-vm ssh <VM_NAME> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --worker=all --batch-size=8 --tunnel-through-iap \
  --command="pip install --user -U 'jax[tpu]' -f https://storage.googleapis.com/jax-releases/libtpu_releases.html"
# ⚠️ Don't assume installing jax alone is enough! Your task's optax / flax / numpyro etc. also need installing — field-tested: someone installed only jax,
#    missed optax, and all 16 nodes crashed on import optax. **Recommended: just run `pip install -r requirements.txt` to install everything at once.**
# ⚠️ Cap batch-size at 8: 16 concurrent SSH handshakes hit sshd MaxStartups (default 10:30:100) → intermittent 255.
# ⚠️ For verification don't actually import jax (importing on TPU grabs /tmp/libtpu_lockfile and stalls, leaving a lock-holding orphan that breaks later jax);
#    only check for the package with find_spec: python3 -c 'import importlib.util as u; print(u.find_spec("jax") is not None)'
# To have the daemon auto-install for you after a claim: set TPU_SETUP_CMD="<your install command>" in resources.conf (leave empty = install nothing).
```

**Four SSH pitfalls**:

| Symptom                                              | Action                                                                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `port 22: Operation timed out`                      | forgot `--tunnel-through-iap`; add it                                                                   |
| `Currently unable to connect to this TPU using IAP` | VM hasn't reached `READY` yet (IAP is always refused during the CREATING phase); wait                  |
| all workers return 255                              | run `ssh-add ~/.ssh/google_compute_engine` locally and retry                                           |
| wanting to hand-write `for worker ... &` for concurrency | **forbidden** — 16 concurrent handshakes hit sshd MaxStartups (default 10:30:100) + retry self-amplification → intermittent 255 gets worse the more you try; always use `--worker=all --batch-size=8` |

Also: **port 22 between workers is not open**, so don't scp from worker A to worker B;
always distribute files from the local machine with `$GCLOUD ... scp --worker=all`.

### 7.5 Multi-host slice notes (v5e-64 / v6e-64 = 16 hosts)

A 64-chip slice is an atomic unit of **16 hosts × 4 chips**, not one big machine:

- To run a true multi-host job, **every worker must call** `jax.distributed.initialize()` (otherwise each sees only its local 4 chips)
- Multi-controller JAX defaults to **"one crashes, all crash"**: any host going unreachable = the whole slice is void = the whole QR re-queued; don't expect a single host to self-heal
- **Don't run `jax.device_count()` / `local_device_count()` / `jax.devices()` from a single SSH to verify chips** — any
  device operation triggers multi-host backend init, and a single process can't sync with the other hosts → stalls >60s (field-tested: global stalls, local stalls too).
  Chip visibility is a distributed operation; it requires all hosts to call `jax.distributed.initialize()` at the same time (= the entry script of your actual job),
  not something setup can confirm from a single point. Setup only confirms `import jax` is installed.

> **Multi-host pitfalls during training runs (this repo only sets up the machine, it does not take over training — pointers only here; see the official JAX docs for details)**:
> 
> - **Program exit hangs / `Barrier timed out::Shutdown`**: the atexit shutdown barrier registered by `jax.distributed.initialize`
>   defaults to waiting the full `shutdown_timeout` (300s); if any host exits early/crashes at the last step, the rest stall the full timeout.
>   The clean official fix = all hosts call `jax.distributed.shutdown()` at the same point; for a batch job that exits right after finishing you can also `os._exit(rc)` to skip it
>   (field-tested as workable, but `os._exit` **does not flush stdio / does not run atexit**, so manually flush, close, and persist to disk before exiting).
>   Choose between them per situation — when the last step itself crashes, `shutdown()` will stall just the same.
> - **Synchronous checkpoint write mid-training → collective desync → `accelerator device halted prematurely`**:
>   hosts take uneven time writing to disk (or an `if process_index==0` single-point guard takes a different code path) → the subsequent collective
>   has an absent participant → core-halt. The correct fix = **Orbax async checkpoint** (`AsyncCheckpointer`/`CheckpointManager`,
>   background disk write + a separate sync key, isolated from the training collective; MaxText's default); save must be **called by all hosts**,
>   with no outer process_index guard. (Crude workaround: write only once at the last step, giving up mid-training fault tolerance.)

---

## 8. Cleanup when done + billing basics

```bash
# Confirm you created it, then delete
$GCLOUD alpha compute tpus queued-resources delete <queue name> \
  --project=<YOUR_PROJECT_ID> --zone=<ZONE> --force --quiet
```

| Resource                            | Charged?              |
| ----------------------------------- | --------------------- |
| TPU chips                           | free (covered by TRC) |
| worker VM CPU/RAM                   | **charged**           |
| boot disk (default 100GB × worker count) | **charged**      |
| network egress traffic              | **charged**           |
| GCS storage                         | **charged**           |

> A new GCP account has $300 of free credit to offset these incidentals. Spot discipline: add checkpointing to training,
> run sessions in tmux/screen, and pull results back to the local machine or GCS promptly — if you get preempted, you lose everything.

### 8.5 GCS checkpoint (mandatory for spot: it can be preempted any time, and local-only storage is as good as no storage)

Spot instances can be reclaimed any time, taking everything on the VM with them. Write training checkpoints / results **to a GCS bucket**, and pull them back on a new machine after preemption:

```bash
# Create a bucket (one-time; the name is globally unique, use a project prefix)
gcloud storage buckets create gs://<YOUR_PROJECT_ID>-tpu --location=<REGION> --project=<YOUR_PROJECT_ID>

# In training, write checkpoints straight to GCS (frameworks natively support gs:// paths, e.g. Orbax / tf.train)
#   ckpt_dir = "gs://<YOUR_PROJECT_ID>-tpu/run1/ckpt"

# Or manually: push local results up from worker 0 (the worker has GCS write permission, over the internal network)
$GCLOUD alpha compute tpus tpu-vm ssh <VM_NAME> --project=<YOUR_PROJECT_ID> --zone=<ZONE> \
  --worker=0 --tunnel-through-iap \
  --command="gcloud storage cp -r ~/outputs gs://<YOUR_PROJECT_ID>-tpu/run1/"

# After preemption, pull back: on the local machine or a new VM
gcloud storage cp -r gs://<YOUR_PROJECT_ID>-tpu/run1/ckpt ./ckpt
```

> GCS storage is billed (cheaply), but it's worth more than a lost experiment. The daemon only handles "claiming the machine back"; **resuming = your training script restoring from the GCS ckpt** (see the limitations section in the README).

> **The truth about the spot preemption window (don't just trust autocheckpoint)**: spot preemption gives only a **~30s** best-effort shutdown window
> (the 120s preemption notice is Preview and not guaranteed for spot; the 5min grace of `--autocheckpoint-enabled` only applies to
> **maintenance events**, not spot preemption). So **don't gamble on "saving once at the instant of preemption"** — for a short run the safe approach is
> **proactively flushing the ckpt to GCS after each unit of work completes (epoch / restart / stage)** (or scp it back locally), so preemption only loses the current
> unfinished segment. The official landing spot is GCS (configure Orbax `CheckpointManager`); scp back to local is unofficial but equally effective for "can it
> be saved at the instant of preemption", at the cost of giving up step-level resume.

---

## 9. Pitfall quick-reference (check here first when you hit an error — all field-tested)

| Symptom / error                                                    | Root cause                  | Action                                          |
| ------------------------------------------------------------------ | --------------------------- | ----------------------------------------------- |
| `--spot` reports `STANDARD provisioning model is incompatible`     | wrong flag                  | use `--provisioning-model=SPOT`                 |
| create FAILED + `IN_USE_ADDRESSES limit`                           | external IP quota 8 < host count | `--internal-ips` + the §4 network trio       |
| `DeleteQueuedResource is not supported when state is PROVISIONING` | state machine restriction   | wait for ACTIVE/FAILED, then delete             |
| PROVISIONING stalls 1-2h                                           | Google is assembling 16 hosts | normal, wait; VM state flapping CREATING↔NOT_CREATED is also normal |
| `no more capacity in zone`                                         | that zone's spot pool is empty | switch zones to queue, don't retry rapidly in place |
| SSH `port 22 timed out`                                            | didn't go through IAP        | add `--tunnel-through-iap`                       |
| IAP `Currently unable to connect`                                  | VM hasn't reached READY      | wait for READY then connect                     |
| ssh/scp all return 255                                             | ssh-agent didn't load the key | `ssh-add ~/.ssh/google_compute_engine`          |
| all workers unreachable after hand-written concurrent scp          | the IAP tunnel pool is blown | stop and wait 10-15min, only use `--worker=all` going forward |
| pip install jax[tpu] silently fails (yet says done)                | region has no NAT, no outbound | add the Router+NAT from §4                     |
| `jax.device_count()` ModuleNotFoundError / can't see chips         | the runtime image has no JAX | install `jax[tpu]` per §7.4                      |
| long-loop gcloud suddenly asks to re-select account                | auth drift                  | add `--account=` to every command, export `CLOUDSDK_CORE_ACCOUNT` |
| `gcloud: command not found` (AI environment)                       | not on PATH                 | `export GCLOUD=$(which gcloud)` and use the absolute path |
| spot drops mid-use, state SUSPENDED                                | preempted by Google, normal  | delete + re-queue; back up important results early |

---

## 10. AI self-check instructions (when a command errors / versions don't match)

In order:

1. First check the §9 quick-reference table in this file
2. `$GCLOUD alpha compute tpus versions list --zone=<ZONE>` (note: the list may not include the latest alpha runtime; reference only)
3. WebFetch / browse the official docs to verify:
   - runtime versions: https://cloud.google.com/tpu/docs/runtimes
   - queued resources API: https://cloud.google.com/tpu/docs/queued-resources
   - zone availability: https://cloud.google.com/tpu/docs/regions-zones
   - TRC FAQ: https://sites.research.google/trc/faq/
4. Still stuck → have the user email trc-support@google.com or go to the Discord `#tpu-research-cloud`
