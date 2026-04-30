# drift-detector-cfn-templates

CloudFormation templates for testing the **iac-drift-saas** drift detection solution from the perspective of a customer AWS account.

The stacks range from a single resource (low complexity) to a 13-resource event-driven pipeline (high complexity) to exercise the drift detection LLM across diverse AWS service types and configuration surfaces.

---

## Repository Structure

```
stacks/
├── 01-s3-basic/              # Single S3 bucket
├── 02-s3-advanced/           # S3 with versioning, lifecycle, and bucket policy
├── 03-iam-role/              # IAM role with inline and managed policies
├── 04-security-groups/       # Layered security groups with cross-references
├── 05-lambda/                # Lambda function with IAM role and log group
├── 06-sns-sqs/               # SNS topic with SQS subscriber and queue policy
├── 07-vpc-networking/        # VPC with public/private subnets, IGW, route tables
├── 08-ec2-instance/          # EC2 instance with instance profile and security group
├── 09-cloudwatch/            # CloudWatch log group, metric filter, and alarms
└── 10-event-pipeline/        # Full event-driven pipeline (S3, SQS, SNS, Lambda, IAM, CloudWatch)
```

Each stack directory contains a single `template.yaml`.

---

## Stack Overview

| Stack | Resources | Complexity | Key Drift Targets |
|---|---|---|---|
| `01-s3-basic` | 1 | Low | Tags, bucket name |
| `02-s3-advanced` | 2 | Low-Medium | Versioning toggle, lifecycle retention days, bucket policy statements |
| `03-iam-role` | 1 | Low-Medium | Managed policy list, inline policy actions, `MaxSessionDuration` |
| `04-security-groups` | 3 | Medium | Ingress/egress rules, CIDR ranges, port ranges |
| `05-lambda` | 3 | Medium | Timeout, memory size, environment variables, runtime |
| `06-sns-sqs` | 4 | Medium | Visibility timeout, message retention period, `RawMessageDelivery` |
| `07-vpc-networking` | 12 | Medium-High | CIDR blocks, `MapPublicIpOnLaunch`, route destinations |
| `08-ec2-instance` | 4 | Medium-High | Instance type, security group rules, `Monitoring` flag |
| `09-cloudwatch` | 6 | Medium-High | Alarm thresholds, evaluation periods, `TreatMissingData`, log retention |
| `10-event-pipeline` | 13 | High | Batch size, reserved concurrency, DLQ `maxReceiveCount`, redrive policy, env vars |

---

## Deploying a Stack

```bash
# Standalone stack (no parameters required)
aws cloudformation deploy \
  --template-file stacks/01-s3-basic/template.yaml \
  --stack-name drift-test-01 \
  --capabilities CAPABILITY_NAMED_IAM

# Stack requiring VPC and Subnet parameters (08-ec2-instance)
aws cloudformation deploy \
  --template-file stacks/08-ec2-instance/template.yaml \
  --stack-name drift-test-08 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides VpcId=vpc-xxxxxxxx SubnetId=subnet-xxxxxxxx
```

### Parameter Requirements

| Stack | Required Parameters |
|---|---|
| `01` through `03`, `05` through `07`, `09` through `10` | None |
| `04-security-groups` | `VpcId` |
| `08-ec2-instance` | `VpcId`, `SubnetId` |

> **Tip:** Deploy `07-vpc-networking` first to get a VPC and subnets you can pass to stacks `04` and `08`.

---

## Deleting a Stack

```bash
aws cloudformation delete-stack --stack-name drift-test-01
```

> **Note:** Stack `08-ec2-instance` provisions a `t2.micro` EC2 instance. Delete this stack when not actively testing to avoid charges.

---

## Simulating Drift

To test the drift detection capability, deploy a stack then manually modify one or more of its resources through the AWS Console or CLI — without updating the CloudFormation template. Examples:

- **S3:** Disable versioning on a bucket where versioning is enabled in the template
- **IAM:** Attach an additional managed policy to a role, or modify an inline policy action
- **Security group:** Add or remove an ingress rule, or change a CIDR range
- **Lambda:** Increase the timeout or change an environment variable value
- **CloudWatch:** Raise or lower an alarm threshold
- **SQS:** Change the visibility timeout or message retention period

The drift detector should identify the delta between the deployed template and the live resource configuration.
