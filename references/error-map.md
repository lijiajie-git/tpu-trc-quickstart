# TPU error-map — error → root cause → handling

> Check here first when you hit an error. All field-tested from GCP TPU queued-resources + IAP scenarios.
> `last-verified: 2026-06-11 / gcloud SDK 562.0.0`(error originals/flags drift with the SDK, see CHANGELOG.md)

---

## 0. FAILED three-way classification(most important — decides "re-queue" vs "stop")

A QR turning `FAILED` is not one single thing. Run `gcloud alpha compute tpus queued-resources describe <QR>` and read the error, classifying into three categories:

| Category | Criterion(error.message) | Meaning | Handling |
|---|---|---|---|
| **capacity**(should retry) | `code: 8` `There is no more capacity in the zone` / `GCE_STOCKOUT` / `ZONE_RESOURCE_POOL_EXHAUSTED` | Quota exists, but the zone's spot pool has no stock right now | delete + re-queue in another/same zone; hedge with multi-zone fanout |
| **structural block**(should stop) | `PERMISSION_DENIED ... check billing` / `billingEnabled: false` / `Limit: 0` / `RESOURCE_EXHAUSTED`(quota) / `NO_VALID_BILLING_ACCOUNT` | Quota not granted / billing off / permission issue | **stop**, do not re-queue(it will never succeed), check billing or contact the TRC/project owner |
| **unknown** | other | Never seen before | Default to one capacity re-queue, keep observing |

### Quota value three readings(`gcloud beta quotas info describe ... --format="yaml(dimensionsInfos)"`)

| In dimensionsInfos | Meaning |
|---|---|
| `value: '64'` | That (type, zone) is enough for one 64-chip slice |
| `value: '0'` | Explicit zero(deliberately not given) |
| `details: {}`(value missing) | **Not granted**(TRC gave no quota for this type in this zone)→ a queue here will always FAILED |

---

## 1. Queue / create

| Symptom | Root cause | Handling |
|---|---|---|
| `STANDARD provisioning model is incompatible with spot requests` | Old SDK doesn't recognize `--spot` | Use `--provisioning-model=SPOT`(new SDK accepts both) |
| Create FAILED + `IN_USE_ADDRESSES limit: 8.0` | External IP quota < host count(v5e-64=16) | Add `--internal-ips`(+ enable Private Google Access + Cloud NAT in the region) |
| `DeleteQueuedResource is not supported when state is PROVISIONING` | State machine constraint | Wait until ACTIVE or FAILED, then delete. **PROVISIONING can stall 1-2h then still succeed, which is normal** |
| Queuing two same-type QRs in the same zone gives no speedup | Same capacity pool + colliding on the same zone quota slot | Queue only one per zone; for parallelism go to **another zone that has quota** |
| Multi-zone fanout claims one, the other still hangs | The loser QR isn't cleaned up, occupies a slot / burns VM money once ACTIVE | Immediately `delete --async` the remaining losers once you claim; if PROVISIONING can't be deleted, note it for later cleanup |

---

## 2. SSH / IAP

| Symptom | Root cause | Handling |
|---|---|---|
| `port 22: Operation timed out` | Not going through IAP | Add `--tunnel-through-iap` to all ssh/scp |
| `Currently unable to connect to this TPU using IAP` | VM not yet `READY`(IAP always rejects during CREATING) | Wait for `state=READY` then connect |
| All workers return 255(intermittent) | **255 is OpenSSH's generic code, not a GCP error**; gcloud's "add ssh key to ssh-agent" is just a guess and often not the real cause | First `ssh-add ~/.ssh/google_compute_engine`; if it still hangs see "255 retry storm" below |
| `--worker=all --batch-size=16` most workers intermittently 255, worse the more you retry | **Not IAP**(low confidence): sshd `MaxStartups` defaults to `10:30:100`, 16 concurrent handshakes through IAP get slower → pre-auth bucket likely drops past 10; blind retries **self-amplify** | Lower `--batch-size=4~8`; reuse one connection with SSH `ControlMaster`/`ControlPersist`; back off + cap retries; stop and let the backlog drain |
| After background launch(`nohup ... &`)SSH won't exit, 255 retries | The background job inherits the SSH exec channel's fd → the channel never EOFs → gcloud treats it as "didn't exit cleanly" and retries | `setsid <cmd> </dev/null >log 2>&1 &` then explicit `exit 0` |
| `Too many authentication failures` → 255 | ssh-agent loaded with too many keys, sshd tries a few then drops | `--ssh-flag="-o IdentitiesOnly=yes"` + keep only the 1 needed key in the agent |
| scp from worker A to worker B times out | Port 22 isn't reachable between workers | Distribute files only from the local host with `--worker=all` |
| Large files(npz/ckpt)`scp --worker=all` slow / hits handshake rate limit | One IAP tunnel per worker, 16 concurrent large-file scps again hit MaxStartups | Send bulk via **GCS**: local `gsutil cp` to bucket → `--worker=all 'gsutil cp gs://... .'`(each goes over the internal network, bypassing IAP); reserve IAP scp for small files / single worker |
| Want to kill the 255 storm / MaxStartups at the root(biggest lever) | 16 independent SSH handshakes → reuse into 1 master connection | Configure OpenSSH multiplexing in `--ssh-flag`: `-o ControlMaster=auto -o ControlPath=~/.ssh/cm-%C -o ControlPersist=300`, the first builds the master and the rest reuse it, no longer hitting MaxStartups. **Note: combining with `--tunnel-through-iap` is not yet widely field-tested**, verify on a small batch first |

> **255 retry storm — multi-cause ranking**(verified against GCP docs): A client ssh-agent unreachable(background shell can't reach the agent)→ `--ssh-key-file`;
> B **sshd MaxStartups 10:30:100** + retry flood self-amplifying(**best fit**: intermittent / worse the more you retry / resolves when you stop and let the backlog drain)→ batch-size ≤8 + ControlMaster + backoff cap;
> C background fd doesn't EOF → `setsid`; D metadata key quota(36/min, low); E **IAP TCP-forward rate limit = low confidence**(no public concurrency number, reports 429 not 255).
> Diagnose with `--ssh-flag="-vvv"` to distinguish `Too many authentication failures`(client)/ 429-412(quota)/ tunnel timeout(IAP).

---

## 3. Environment / configuration

| Symptom | Root cause | Handling |
|---|---|---|
| `gcloud: command not found` | Not on PATH | `GCLOUD="${GCLOUD:-$(command -v gcloud || echo /opt/homebrew/bin/gcloud)}"` |
| Long-running gcloud loop suddenly asks to re-pick an account | Default account drift | Pass `--account=` on every command; `export CLOUDSDK_CORE_ACCOUNT`/`_PROJECT` as fallback |
| Default project drifts to an unrelated project | Config drift | Always pass `--project=` explicitly |
| pip install `jax[tpu]` silently fails(yet reports done) | Region has no NAT, worker can't reach the internet | Add Cloud Router + NAT; PGA doesn't cover PyPI |
| `jax.device_count()` ModuleNotFoundError / chips not visible | Runtime image doesn't include JAX | `pip install -U 'jax[tpu]' -f .../libtpu_releases.html` |
| Every restart recompiles JAX ~90s(especially painful after a preemption rebuild) | No XLA compilation cache directory set, compiles HLO from scratch each time | Before `import jax` export `JAX_COMPILATION_CACHE_DIR=$HOME/.jax_compilation_cache` → warm hit **8-10s**. The cache key includes JAX version / code hash(even a docstring change misses)/ input shape+dtype / compile flags; for multi-scenario, pad constant arrays to a uniform shape to raise the hit rate |
| **`import jax` hangs forever / every later jax process also hangs** | A previous stuck jax process(often a verification probe)didn't die, **holds `/tmp/libtpu_lockfile`**(libtpu single-instance lock)→ all later jax is blocked | Kill the leftover jax process(use a bracket: `pkill -9 -f '[i]mport jax'`, **not `pkill -f 'import jax'`** which self-matches and kills your own SSH shell)+ `rm -f /tmp/libtpu_lockfile`, then retry |
| **When checking whether jax is installed, don't actually `import jax`** | On a TPU `import jax` initializes libtpu + grabs the lock; if it hangs it leaves a lock-holding orphan, a pitfall for the next one | Use `python3 -c 'import importlib.util as u; print(u.find_spec("jax") is not None)'`(only checks the package without executing, doesn't touch the TPU, doesn't grab the lock) |
| **Multi-host all stuck on `RegisterTask` / `CoordinationService`**, `jax.distributed.initialize()` never returns, no training step | The python process from the previous crashed run didn't truly die(often because kill silently failed / returned 255), the leftover process still holds the coordination service(port / stale registration)→ the new run's RegisterTask barrier can't assemble; each extra python per host(e.g. py=2, normal is 1)is an orphan | First stop the local driver → `--worker=all` count python per host, **loop kill until 0 on every host** → `rm -f /tmp/libtpu_lockfile`(same nest, see the row above)→ **`sleep ~10s` to let the coordinator port release**(socket teardown isn't instant)→ then restart; **wait-forever guard**: cap the poll(~20min no progress)then kill+skip, don't let the barrier burn an hour |
| kill reports "success" but the process is still there, the next run won't start | An SSH kill returning **255 is the command itself failing, not "no process"**, misread as "cleared"; or pkill self-matched and only killed its own shell(see the row below) | After kill **re-verify**: `--worker=all` recount py processes, only call it clean when it loops to 0; **distinguish SSH failure(255)from a true 0 processes**, don't treat a probe failure as cleared |
| **Multi-host missed scattering an input file**(some worker lacks a data file)→ that role(often the leader)crashes, the rest hang on the barrier waiting | Input was scattered only to some workers; once the leader exits, the collective waits forever | Scatter input to **all hosts** with `--worker=all`; after launch leave a **~2min crash quick-check**(see whether the leader exits in seconds), don't wait for the barrier timeout to find out |
| On v5e `ls /dev/accel*` = empty, assume no chips | **v5e uses `/dev/vfio` not `/dev/accel`** | The devices are actually there; don't use `/dev/accel*` to judge whether a v5e has chips |
| `pkill -f '<command containing this string>'` kills itself / the SSH shell(255) | pkill `-f` matches the whole command line, **including the shell layer running it**(cmdline contains the same string)→ self-match | Bracket trick: wrap the first character in `[]`, e.g. `[i]mport jax` / `[d]river\.py` — the literal string no longer appears in the command line, no self-match |
| **Remote `--command` with `pgrep/pkill -f X` self-matches**(TPU=Linux/procps)→ verified-kill is forever `0/N responded`, `py==0`("all exited")never triggers, worker-0 probe forever alive | The whole `gcloud ssh --command='...pgrep/pkill -f X...'` string is the remote shell's `/proc/PID/cmdline`, X is literally inside it → it counts/kills its own shell layer too; pkill even **kills itself first** → the later `echo` produces no output → looks like "rate-limited 0/N", actually self-harm | The remote pattern **also needs a bracket**: `pkill -9 -f '[d]river'`, `pgrep -f '[p]ython3 -c'`; otherwise kill verification is a no-op and the run won't exit early(empty polling to the cap). **macOS's BSD pgrep doesn't reproduce it, verify on Linux** |
| `versions list` doesn't show some alpha runtime | That list is incomplete | Use the version the docs give as usual, it builds successfully in practice; the list is only for reference |
| macOS has no `timeout` command | That's a Linux thing | Time-limit SSH with gcloud `--ssh-flag="-o ConnectTimeout=15"` |
| macOS bash 3.2 `declare -A: invalid option` | The bundled bash 3.2 has no associative arrays | Use plain index-based arrays, or brew-install a newer bash |

---

## 4. spot preemption / marker

| Symptom | Root cause | Handling |
|---|---|---|
| QR `SUSPENDED` + VM `PREEMPTED` | spot reclaimed | delete + re-queue(auto-recovery is basically hopeless); back up results early |
| After spot preemption the **task fakes being alive and spins idle for hours**(process exists but step doesn't advance, RESP=0) | Preemption only reclaims compute, the driver/SSH may not get the signal, the node is already unreachable but hasn't exited | After it's running add a **runtime liveness probe**: periodically ping the node / check whether the step advances, **node unreachable or RESP=0 → abort immediately**, don't spin idle |
| At the preemption instant the ckpt didn't save / lost a chunk | spot preemption gives only a **~30s** best-effort window(`--autocheckpoint`'s 5min grace is for maintenance, not for spot) | **Don't bet on grabbing a save at preemption**: every time you finish a work unit(epoch/restart/stage)proactively write to GCS / scp back to local(see SKILL §8.5) |
| local marker says claimed but the VM is gone / preempted | spot rebuilt under the same name or deleted, the old flag is stale | Before trusting the marker re-verify with `vm describe`: exists + READY + createTime matches; if not → clear the flag and re-claim |
| spot dies after just a few hours | Normal, spot is surplus compute | checkpoint + tmux/screen + back up results promptly; on-demand quota as fallback |
| Deleted the QR and it pops back on its own / preempted again after shutdown | The daemon is still alive, the QR health check sees MISSING → auto re-queues | **Kill the daemon before deleting the QR**: `touch /tmp/tpu_daemon.stop; pkill -9 -f tpu_daemon.sh`, confirm `pgrep -af tpu_daemon.sh` is empty before deleting; after deleting re-scan to confirm no revival |

---

## 5. Billing(free chips ≠ free machine)

| Resource | Charged? |
|---|---|
| TPU chips | Free(TRC) |
| worker VM CPU/RAM | **Charged** |
| Boot disk(default 100GB × worker count) | **Charged** |
| Egress traffic / cross-region egress | **Charged** |
| GCS storage | **Charged** |

delete immediately when done; the daemon exiting at 6h does **not** auto-delete already-claimed VMs, remember to clean up manually. A new GCP account's $300 credit can offset this.
