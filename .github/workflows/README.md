# GitHub Actions CI/CD Workflow

## Overview

`deploy.yml` provides a two-stage CI/CD pipeline for CloudFormation template changes. It triggers automatically on any pull request or push that touches a file matching `stacks/*/template.yaml`.

```
Pull Request opened / updated
        │
        ▼
  [ validate job ]
  aws cloudformation validate-template
  on each changed template
        │
        ▼ (pass)
  PR approved and merged
        │
        ▼
   [ deploy job ]
  aws cloudformation deploy
  for each changed stack only
```

---

## Triggers

| Event | Condition | Job that runs |
|---|---|---|
| `pull_request` targeting `main` | Any `stacks/*/template.yaml` changed | `validate` |
| `push` to `main` | Any `stacks/*/template.yaml` changed | `deploy` |

The `paths` filter ensures the workflow is a no-op for changes to non-template files (docs, scripts, etc.).

---

## Jobs

### validate

Runs on every pull request. For each `template.yaml` that differs from `main`, it calls `aws cloudformation validate-template` via the AWS API. This catches YAML syntax errors, invalid resource types, and malformed property values before the PR is merged.

**Steps:**
1. Checkout the branch with full history (`fetch-depth: 0`) so the diff against `origin/main` is accurate.
2. Configure AWS credentials from GitHub Secrets.
3. Compute the list of changed templates using `git diff --name-only origin/<base>...HEAD`.
4. Iterate over each file and call `validate-template`. Any failure exits non-zero, blocking the merge.

### deploy

Runs after a merge to `main`. Detects which templates changed in the merge commit and deploys only those stacks — not all 10.

**Steps:**
1. Checkout with `fetch-depth: 2` to expose the parent commit for the diff.
2. Configure AWS credentials from GitHub Secrets.
3. Compute changed templates using `git diff --name-only <before-sha> <after-sha>`.
4. Sort the list so stacks always deploy in numeric order (important for dependency ordering — stack 07 before stacks 04 and 08).
5. Fetch VPC outputs from `drift-test-07` upfront (needed as parameters for stacks 04 and 08).
6. Deploy each changed stack with `aws cloudformation deploy --no-fail-on-empty-changeset`.
7. If stack 07 itself was part of the changeset, re-fetch VPC outputs immediately after it deploys so the updated values are available for stacks 04 or 08 if they follow in the same run.

---

## Stack Naming Convention

The deploy job derives the CloudFormation stack name from the directory path:

```
stacks/01-s3-basic/template.yaml  →  drift-test-01
stacks/08-ec2-instance/template.yaml  →  drift-test-08
```

The two-digit prefix is extracted with `basename "$(dirname "$file")" | grep -o '^[0-9][0-9]'`.

---

## Parameter Handling

Most stacks deploy with no parameters. Two stacks require VPC identifiers:

| Stack | Parameters injected |
|---|---|
| `04-security-groups` | `VpcId` (from `drift-test-07` outputs) |
| `08-ec2-instance` | `VpcId`, `SubnetId` (from `drift-test-07` outputs) |

If `drift-test-07` has no outputs (e.g., it was never deployed), the deploy job logs a `SKIP` for stacks 04 and 08 and exits with a non-zero code so the failure is visible in the Actions UI.

---

## Required Setup

### 1. Add GitHub Secrets

Navigate to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key ID for the deploying IAM user |
| `AWS_SECRET_ACCESS_KEY` | Secret access key for the deploying IAM user |

### 2. IAM Permissions

The IAM user referenced by the secrets must have the following AWS managed policies attached:

| Policy | Required for |
|---|---|
| `AWSCloudFormationFullAccess` | All CloudFormation operations |
| `AmazonSSMReadOnlyAccess` | Resolving SSM-backed AMI parameter in stack 08 |
| `AWSLambda_FullAccess` | Deploying stacks 05 and 10 |
| `CloudWatchLogsFullAccess` | Deploying stacks 09 and 10 |

---

## Node.js Version

The workflow sets `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` in the top-level `env` block. This opts all actions (`actions/checkout`, `aws-actions/configure-aws-credentials`) into Node.js 24 ahead of GitHub's June 2026 forced migration, eliminating deprecation warnings in the Actions UI.

---

## Example Run

**Scenario:** A PR changes `stacks/05-lambda/template.yaml` and `stacks/09-cloudwatch/template.yaml`.

1. PR is opened → `validate` job runs and calls `validate-template` on both files.
2. Both pass → PR can be reviewed and merged.
3. Merge triggers `deploy` job → only `drift-test-05` and `drift-test-09` are redeployed. The other 8 stacks are untouched.
