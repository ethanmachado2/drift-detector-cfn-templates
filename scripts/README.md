# Drift Inducer

## Overview

`drift-inducer.sh` applies out-of-band changes directly to AWS resources across all 10 `drift-test-*` CloudFormation stacks, bypassing CloudFormation entirely. The result is configuration drift — a divergence between what the CloudFormation template declares and what actually exists in AWS — which the iac-drift-saas detection solution is then tested against.

All 10 stacks are processed in parallel (one background shell process per stack), so a full run typically completes in under 15 seconds regardless of stack count.

---

## Prerequisites

- AWS CLI installed and configured (`aws configure` or environment variables)
- Credentials for an IAM user with permissions across EC2, S3, IAM, Lambda, SQS, SNS, CloudWatch Logs, and CloudFormation read access
- All 10 `drift-test-*` stacks must be deployed and in a `CREATE_COMPLETE` or `UPDATE_COMPLETE` state

---

## Usage

Run from the repository root:

```bash
# Round 1 — baseline drift across all 10 stacks (~25 changes)
./scripts/drift-inducer.sh

# Round 2 — larger deltas (higher thresholds, bigger timeouts, more memory)
./scripts/drift-inducer.sh 2

# Round 3 — maximum deltas (ceiling values for stress testing)
./scripts/drift-inducer.sh 3
```

Each run writes a timestamped log file to the current directory:

```
drift-run-20260430-142301-round1.log
```

The log captures every change applied, every skipped operation (e.g., duplicate security group rules), and a final summary showing total changes and elapsed time.

---

## How It Works

### Resource Discovery

The script never hardcodes AWS resource IDs. At runtime, each stack function calls `aws cloudformation describe-stack-resource` to resolve logical resource IDs (e.g., `DriftTestBucket`) into physical IDs (e.g., `drift-test-01-bucket-abc123`):

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

This means the script works correctly regardless of the random suffixes CloudFormation appends to resource names.

### Parallel Execution

Each `drift_NN()` function is launched as a background process. The `main()` function calls all ten with `&` and then blocks on `wait` until all complete:

```bash
drift_01 &
drift_02 &
...
drift_10 &
wait
```

This simulates concurrent drift across multiple stacks simultaneously, stressing the detection pipeline's ability to handle fan-out.

### Change Counting

Each successful change calls `ok()`, which drops an empty file into a temporary directory. After `wait` returns, the number of files in that directory equals the total number of changes applied. The temp directory is cleaned up automatically on exit via `trap`.

### Idempotency

Operations that cannot be duplicated (e.g., adding a security group rule that already exists) are wrapped in a conditional and fall through to a `skip` log line instead of erroring out. This allows the script to be re-run safely without aborting mid-execution.

---

## Changes Per Stack

### Stack 01 — S3 Basic
Adds two extra tags (`DriftInduced=true`, `Round=RoundN`) to the S3 bucket. The template only defines three tags; the extra tags are detectable as drift.

### Stack 02 — S3 Advanced
- Suspends versioning (template: `Enabled`)
- Shortens `NoncurrentVersionExpiration` from 30 days to 7 / 3 / 1 days (rounds 1–3)

### Stack 03 — IAM Role
- Increases `MaxSessionDuration` from 3600s to 7200 / 10800 / 43200s (rounds 1–3)
- Adds a `DriftInducedPolicy` inline policy not present in the template

### Stack 04 — Security Groups
Adds a TCP ingress rule on port 80 / 8080 / 8443 (rounds 1–3) from `0.0.0.0/0` to the `WebServerSG`. The template only permits port 443.

### Stack 05 — Lambda
- Increases timeout from 30s to 60 / 90 / 120s (rounds 1–3)
- Increases memory from 128MB to 256 / 512 / 1024MB (rounds 1–3)
- Adds `DRIFT_INDUCED=true` and `ROUND=N` to the function's environment variables
- Extends log group retention from 7 days to 30 / 60 / 90 days (rounds 1–3)

### Stack 06 — SNS/SQS
- Increases SQS `VisibilityTimeout` from 60s to 120 / 300 / 600s (rounds 1–3)
- Extends `MessageRetentionPeriod` from 1 day to 4 / 7 / 14 days (rounds 1–3)
- Flips SNS subscription `RawMessageDelivery` from `true` to `false`

### Stack 07 — VPC
- Disables `MapPublicIpOnLaunch` on `PublicSubnetA` (template: enabled)
- Adds `DriftInduced=true` and `Round=N` tags directly to the VPC resource

### Stack 08 — EC2 Instance
- Enables detailed monitoring on the instance (template: `Monitoring: false`)
- Adds a TCP port 80 ingress rule to the instance security group using a private CIDR (`10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16` across rounds)

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

---

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

## Restoring Template State

To remove all induced drift and restore stacks to their template-defined state, redeploy each affected stack through CloudFormation:

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --template-file stacks/<NN>-<name>/template.yaml \
  --stack-name drift-test-<NN> \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset
```

CloudFormation will compute a change set and revert any drifted properties back to the values declared in the template.
