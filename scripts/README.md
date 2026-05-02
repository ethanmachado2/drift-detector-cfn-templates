# Scripts

Two scripts are provided for managing drift across the 10 `drift-test-*` stacks.

| Script | Purpose |
|---|---|
| `drift-inducer.sh` | Applies out-of-band changes to all 10 stacks to create detectable drift |
| `reset-stacks.sh` | Destroys all 10 stacks and redeploys them from the local templates |

Both scripts run from the **repository root**, write a timestamped log file, and report an `OK`/`ERR` summary on completion.

---

## Prerequisites

- AWS CLI installed and configured (`aws configure` or environment variables)
- Credentials for an IAM user with permissions across EC2, S3, IAM, Lambda, SQS, SNS, CloudWatch Logs, and CloudFormation
- `python3` available on `PATH` (used by `drift-inducer.sh` for S3 tag merging)

---

---

# drift-inducer.sh

## Overview

Applies out-of-band changes directly to AWS resources across all 10 stacks, bypassing CloudFormation entirely. The result is configuration drift — a divergence between what the template declares and what actually exists in AWS — which the iac-drift-saas detection solution is tested against.

All 10 stacks are processed in parallel (one background shell process per stack), so a full run typically completes in under 15 seconds.

## Usage

```bash
# Round 1 — baseline drift across all 10 stacks (~25 changes)
./scripts/drift-inducer.sh

# Round 2 — larger deltas (higher thresholds, bigger timeouts, more memory)
./scripts/drift-inducer.sh 2

# Round 3 — maximum deltas (ceiling values for stress testing)
./scripts/drift-inducer.sh 3
```

Each run writes a timestamped log file to the repo root:

```
drift-run-20260501-142301-round1.log
```

## How It Works

### Resource Discovery

The script never hardcodes AWS resource IDs. Each stack function calls `aws cloudformation describe-stack-resource` to resolve logical resource IDs (e.g., `DriftTestBucket`) into physical IDs at runtime:

```bash
cfn_resource() {
  aws cloudformation describe-stack-resource \
    --region "$REGION" \
    --stack-name "$1" \
    --logical-resource-id "$2" \
    --query "StackResourceDetail.PhysicalResourceId" \
    --output text
}
```

### Parallel Execution

Each `drift_NN()` function is launched as a background process and all ten run concurrently:

```bash
drift_01 &
drift_02 &
...
drift_10 &
wait
```

### Error Visibility

Every AWS command uses `&& ok "..." || err "..."`. On failure the actual AWS error message is captured from stderr and written to the log, making permission gaps and API errors immediately identifiable without re-running with verbose flags.

### Change Counting

After `wait` returns, the summary counts `OK` and `ERR` lines directly from the log file:

```bash
ok_count=$(grep -c '  OK   ' "$LOG_FILE" || true)
err_count=$(grep -c '  ERR  ' "$LOG_FILE" || true)
```

### Idempotency

Operations that cannot be duplicated (e.g., adding a security group rule that already exists) are wrapped in a conditional and fall through to a `SKIP` log line instead of erroring. The script can be re-run safely without aborting mid-execution.

### S3 Tag Merging

`put-bucket-tagging` replaces the entire tag set, including AWS-managed system tags (`aws:cloudformation:*`) that cannot be omitted. Before writing, the script fetches the existing tags and merges the drift tags in using a Python one-liner, preserving all system tags.

## Changes Per Stack

### Stack 01 — S3 Basic
Adds `DriftInduced=true` and `Round=RoundN` tags to the S3 bucket, merged with existing tags to preserve CloudFormation system tags.

### Stack 02 — S3 Advanced
- Suspends versioning (template: `Enabled`)
- Shortens `NoncurrentVersionExpiration` from 30 days to 7 / 3 / 1 days (rounds 1–3)

### Stack 03 — IAM Role
- Increases `MaxSessionDuration` from 3600s to 7200 / 10800 / 43200s (rounds 1–3)
- Adds a `DriftInducedPolicy` inline policy not present in the template

### Stack 04 — Security Groups
Adds a TCP ingress rule on port 80 / 8080 / 8443 (rounds 1–3) from `0.0.0.0/0` to `WebServerSG`. The template only permits port 443.

### Stack 05 — Lambda
- Increases timeout from 30s to 60 / 90 / 120s (rounds 1–3)
- Increases memory from 128MB to 256 / 512 / 1024MB (rounds 1–3)
- Adds `DRIFT_INDUCED=true` and `ROUND=N` environment variables
- Extends log group retention from 7 days to 30 / 60 / 90 days (rounds 1–3)

### Stack 06 — SNS/SQS
- Increases SQS `VisibilityTimeout` from 60s to 120 / 300 / 600s (rounds 1–3)
- Extends `MessageRetentionPeriod` from 1 day to 4 / 7 / 14 days (rounds 1–3)
- Flips SNS subscription `RawMessageDelivery` from `true` to `false`

### Stack 07 — VPC
- Disables `MapPublicIpOnLaunch` on `PublicSubnetA` (template: enabled)
- Adds `DriftInduced=true` and `Round=N` tags to the VPC resource

### Stack 08 — EC2 Instance
- Enables detailed monitoring (template: `Monitoring: false`)
- Adds a TCP port 80 ingress rule using a private CIDR (`10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16` across rounds)

### Stack 09 — CloudWatch
- Raises `ErrorRateAlarm` threshold from 5 to 10 / 25 / 50 (rounds 1–3)
- Raises `HighErrorRateAlarm` threshold from 20 to 50 / 100 / 200 (rounds 1–3)
- Extends log group retention from 14 days to 30 / 60 / 90 days (rounds 1–3)

### Stack 10 — Event Pipeline
- Increases Lambda timeout from 60s to 120 / 180 / 300s (rounds 1–3)
- Increases Lambda memory from 256MB to 512 / 1024 / 2048MB (rounds 1–3)
- Increases `ProcessingQueue` `VisibilityTimeout` from 300s to 600 / 900 / 1200s (rounds 1–3)
- Reduces `DeadLetterQueue` `MessageRetentionPeriod` from 14 days to 4 days (all rounds)
- Raises `DLQDepthAlarm` threshold from 1 to 5 / 10 / 25 (rounds 1–3)
- Extends log group retention from 14 days to 30 / 60 / 90 days (rounds 1–3)

## Round Reference

| Stack | Property | Template | Round 1 | Round 2 | Round 3 |
|---|---|---|---|---|---|
| 01 | Extra tags | 0 | 2 | 2 | 2 |
| 02 | Versioning | Enabled | Suspended | Suspended | Suspended |
| 02 | Lifecycle expiry | 30 days | 7 days | 3 days | 1 day |
| 03 | MaxSessionDuration | 3600s | 7200s | 10800s | 43200s |
| 04 | Extra SG port | none | 80 | 8080 | 8443 |
| 05 | Lambda timeout | 30s | 60s | 90s | 120s |
| 05 | Lambda memory | 128MB | 256MB | 512MB | 1024MB |
| 05 | Log retention | 7 days | 30 days | 60 days | 90 days |
| 06 | SQS visibility | 60s | 120s | 300s | 600s |
| 06 | SQS retention | 1 day | 4 days | 7 days | 14 days |
| 06 | RawMessageDelivery | true | false | false | false |
| 07 | MapPublicIpOnLaunch | true | false | false | false |
| 08 | EC2 monitoring | false | true | true | true |
| 08 | Extra SG CIDR | none | 10.0.0.0/8 | 172.16.0.0/12 | 192.168.0.0/16 |
| 09 | ErrorRate threshold | 5 | 10 | 25 | 50 |
| 09 | HighErrorRate threshold | 20 | 50 | 100 | 200 |
| 09 | Log retention | 14 days | 30 days | 60 days | 90 days |
| 10 | Lambda timeout | 60s | 120s | 180s | 300s |
| 10 | Lambda memory | 256MB | 512MB | 1024MB | 2048MB |
| 10 | Queue visibility | 300s | 600s | 900s | 1200s |
| 10 | DLQ retention | 14 days | 4 days | 4 days | 4 days |
| 10 | DLQ alarm threshold | 1 | 5 | 10 | 25 |
| 10 | Log retention | 14 days | 30 days | 60 days | 90 days |

---

---

# reset-stacks.sh

## Overview

Destroys all 10 `drift-test-*` stacks and redeploys them from the local templates, restoring every stack to its CloudFormation-defined state. Use this after running `drift-inducer.sh` to reset the environment for the next test cycle.

## Usage

```bash
./scripts/reset-stacks.sh
```

Each run writes a timestamped log file to the repo root:

```
reset-run-20260501-150000.log
```

## Execution Phases

The script runs in three sequential phases:

```
Phase 1  — Delete all 10 stacks in parallel
               ↓ (wait for all deletions)
Phase 2a — Deploy independent stacks in parallel
           (01, 02, 03, 05, 06, 07, 09, 10)
               ↓ (wait for all deployments)
Phase 2b — Fetch VpcId + PublicSubnetAId from drift-test-07
               ↓
Phase 2c — Deploy VPC-dependent stacks in parallel
           (04 with VpcId, 08 with VpcId + SubnetId)
```

### Phase 1 — Delete

All 10 stacks are deleted concurrently. Each background process calls `aws cloudformation delete-stack` followed by `aws cloudformation wait stack-delete-complete`. If a stack was already absent the wait exits non-zero; the script confirms the actual stack state before logging `OK` or `ERR`.

Stack 08 (EC2 instance) is typically the slowest to delete (~2–3 minutes). Running all deletions in parallel means total Phase 1 time is bounded by the slowest single deletion rather than the sum of all.

### Phase 2a — Independent Deploys

Stacks with no parameter dependencies deploy in parallel. Stack 07 (`drift-test-07`, the VPC) is included here — its outputs are consumed in Phase 2b.

### Phase 2b — VPC Output Lookup

After all Phase 2a deployments complete, the script queries `drift-test-07` for `VpcId` and `PublicSubnetAId`. If either value is missing the script logs an `ERR` and skips Phase 2c.

### Phase 2c — VPC-Dependent Deploys

Stacks 04 and 08 deploy in parallel with their required parameters injected:

| Stack | Parameters |
|---|---|
| `drift-test-04` | `VpcId` |
| `drift-test-08` | `VpcId`, `SubnetId` |

## Typical Runtime

| Phase | Duration |
|---|---|
| Phase 1 (delete) | ~3–5 min (bounded by EC2 instance deletion) |
| Phase 2a (deploy independent) | ~3–5 min |
| Phase 2c (deploy VPC-dependent) | ~2–3 min |
| **Total** | **~8–13 min** |

## Notes

- If a stack is in `DELETE_FAILED` state when the script runs, `delete-stack` will re-attempt deletion. If it still fails, an `ERR` line is logged and the corresponding deploy in Phase 2 will also fail since the stack is in a broken state. Resolve the deletion manually in the CloudFormation console before re-running.
- Stack 08's `AmiId` resolves automatically via SSM — no override is needed.
- The script is safe to re-run; all deploys use `--no-fail-on-empty-changeset`.
