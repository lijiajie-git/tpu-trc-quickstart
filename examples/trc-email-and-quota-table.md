# Example: Parsing a quota table from the TRC email

> The AI's first step is to read the user's TRC welcome email and produce a quota table
> before starting work. Below is a redacted sample +
> the expected output, for the AI to align against.

## Input: TRC welcome email (redacted sample)

```
Subject: Welcome to the TPU Research Cloud

Hi,

Congratulations! Your application to the TPU Research Cloud has been approved.
The following quota has been added to your Google Cloud project:

  - 64  TPU v5e cores  in zone europe-west4-b   (preemptible)
  - 64  TPU v5e cores  in zone us-central1-a    (preemptible)
  - 32  TPU v4  cores  in zone us-central2-b    (on-demand)

This access is valid for 30 days from today. Cloud TPUs are provided at no
charge, but other Google Cloud resources (VM CPU, disk, network, storage) are
billed normally.

We ask that you share your research results publicly and give us feedback.

— The TPU Research Cloud Team
```

## Expected output: quota table (the AI produces this first, after parsing)

| Accelerator | Chips | zone | Billing model | accelerator-type | runtime | host count | Needs --internal-ips |
|---|---|---|---|---|---|---|---|
| v5e | 64 | europe-west4-b | preemptible (spot) | v5litepod-64 | v2-alpha-tpuv5-lite | 16 | Yes |
| v5e | 64 | us-central1-a | preemptible (spot) | v5litepod-64 | v2-alpha-tpuv5-lite | 16 | Yes |
| v4 | 32 | us-central2-b | on-demand | v4-32 | tpu-ubuntu2204-base | 4 | No |

Valid for: 30 days from approval. Chips are free; VM/disk/traffic are billed.

## Queueing decisions based on this

- Both v5e zones are spot and each has quota → **dual-zone fanout** (higher claim rate; once one is claimed, cancel the other)
- v4-32 is on-demand → won't be preempted, serves as a stable fallback (but with half the chips)
- The 16-host v5e requires `--internal-ips` (IP quota is only 8)
- Before queueing, confirm the zone actually has quota with `gcloud beta quotas info` (`details: {}` = not granted; queueing will always FAIL)
