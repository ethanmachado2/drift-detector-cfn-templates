#!/usr/bin/env bash
# drift-inducer.sh
#
# Applies out-of-band changes directly to AWS resources across all 10 drift-test
# stacks, bypassing CloudFormation to create detectable configuration drift.
# All 10 stacks are processed in parallel to stress-test drift detection scaling.
#
# Usage:
#   ./scripts/drift-inducer.sh          # single run
#   ./scripts/drift-inducer.sh 2        # round 2 (larger deltas)
#   ./scripts/drift-inducer.sh 3        # round 3 (restore-like changes)
#
# Prerequisites: AWS CLI configured with credentials for terraform-iam-user.

set -uo pipefail

REGION="us-east-1"
ROUND="${1:-1}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="drift-run-${TIMESTAMP}-round${ROUND}.log"
COUNTER_DIR=$(mktemp -d)
trap 'rm -rf "$COUNTER_DIR"' EXIT

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
ok()   { log "  OK   $*"; touch "$COUNTER_DIR/c_${BASHPID}_${RANDOM}"; }
skip() { log "  SKIP $*"; }
err()  { log "  ERR  $*"; }

cfn_resource() {
  aws cloudformation describe-stack-resource \
    --region "$REGION" \
    --stack-name "$1" \
    --logical-resource-id "$2" \
    --query "StackResourceDetail.PhysicalResourceId" \
    --output text
}

# ── Stack 01: S3 Basic ────────────────────────────────────────────────────────
# Drift: add out-of-band tags not present in the template
drift_01() {
  local bucket
  bucket=$(cfn_resource drift-test-01 DriftTestBucket)
  log "[01] S3 Basic — tag drift on $bucket"

  local extra_tag="Round${ROUND}"
  aws s3api put-bucket-tagging --region "$REGION" --bucket "$bucket" \
    --tagging "TagSet=[
      {Key=Environment,Value=test},
      {Key=ManagedBy,Value=CloudFormation},
      {Key=DriftTest,Value=01},
      {Key=DriftInduced,Value=true},
      {Key=Round,Value=${extra_tag}}
    ]"
  ok "[01] Added DriftInduced+Round tags to $bucket"
}

# ── Stack 02: S3 Advanced ─────────────────────────────────────────────────────
# Drift: suspend versioning (template: Enabled); shorten lifecycle expiration
drift_02() {
  local bucket
  bucket=$(cfn_resource drift-test-02 DriftTestBucket)
  log "[02] S3 Advanced — versioning + lifecycle drift on $bucket"

  aws s3api put-bucket-versioning --region "$REGION" --bucket "$bucket" \
    --versioning-configuration Status=Suspended
  ok "[02] Versioning Enabled → Suspended on $bucket"

  local days=7
  [[ "$ROUND" -eq 2 ]] && days=3
  [[ "$ROUND" -eq 3 ]] && days=1
  aws s3api put-bucket-lifecycle-configuration --region "$REGION" \
    --bucket "$bucket" \
    --lifecycle-configuration "{
      \"Rules\": [{
        \"ID\": \"drift-test-lifecycle\",
        \"Status\": \"Enabled\",
        \"Filter\": {\"Prefix\": \"\"},
        \"NoncurrentVersionExpiration\": {\"NoncurrentDays\": ${days}}
      }]
    }"
  ok "[02] Lifecycle NoncurrentVersionExpiration 30 → ${days} days on $bucket"
}

# ── Stack 03: IAM Role ────────────────────────────────────────────────────────
# Drift: increase MaxSessionDuration; inject extra inline policy
drift_03() {
  local role
  role=$(cfn_resource drift-test-03 DriftTestRole)
  log "[03] IAM Role — MaxSessionDuration + inline policy drift on $role"

  local duration=7200
  [[ "$ROUND" -eq 2 ]] && duration=10800
  [[ "$ROUND" -eq 3 ]] && duration=43200
  aws iam update-role --role-name "$role" --max-session-duration "$duration"
  ok "[03] MaxSessionDuration 3600 → ${duration}s on $role"

  aws iam put-role-policy \
    --role-name "$role" \
    --policy-name DriftInducedPolicy \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:ListAllMyBuckets\", \"s3:GetBucketLocation\"],
        \"Resource\": \"*\",
        \"Condition\": {\"StringEquals\": {\"aws:RequestedRegion\": \"${REGION}\"}}
      }]
    }"
  ok "[03] DriftInducedPolicy inline policy added to $role"
}

# ── Stack 04: Security Groups ─────────────────────────────────────────────────
# Drift: add HTTP ingress rule absent from template (template only has HTTPS/443)
drift_04() {
  local sg
  sg=$(cfn_resource drift-test-04 WebServerSG)
  log "[04] Security Groups — extra ingress rule on $sg"

  local port=80
  [[ "$ROUND" -eq 2 ]] && port=8080
  [[ "$ROUND" -eq 3 ]] && port=8443
  if aws ec2 authorize-security-group-ingress --region "$REGION" \
      --group-id "$sg" \
      --protocol tcp --port "$port" --cidr 0.0.0.0/0 2>/dev/null; then
    ok "[04] Added port $port/0.0.0.0/0 ingress to $sg"
  else
    skip "[04] Port $port rule already exists on $sg"
  fi
}

# ── Stack 05: Lambda ──────────────────────────────────────────────────────────
# Drift: increase timeout + memory; change LOG_LEVEL; extend log retention
drift_05() {
  local fn log_group
  fn=$(cfn_resource drift-test-05 DriftTestFunction)
  log_group=$(cfn_resource drift-test-05 FunctionLogGroup)
  log "[05] Lambda — timeout/memory/env/log-retention drift on $fn"

  local timeout=60 memory=256
  [[ "$ROUND" -eq 2 ]] && timeout=90  && memory=512
  [[ "$ROUND" -eq 3 ]] && timeout=120 && memory=1024
  aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$fn" \
    --timeout "$timeout" \
    --memory-size "$memory" \
    --environment "Variables={ENV=test,LOG_LEVEL=DEBUG,DRIFT_INDUCED=true,ROUND=${ROUND}}" \
    > /dev/null
  ok "[05] Lambda timeout 30 → ${timeout}s, memory 128 → ${memory}MB on $fn"

  local retention=30
  [[ "$ROUND" -eq 2 ]] && retention=60
  [[ "$ROUND" -eq 3 ]] && retention=90
  aws logs put-retention-policy --region "$REGION" \
    --log-group-name "$log_group" --retention-in-days "$retention"
  ok "[05] Log retention 7 → ${retention} days on $log_group"
}

# ── Stack 06: SNS/SQS ─────────────────────────────────────────────────────────
# Drift: increase visibility timeout + retention; flip RawMessageDelivery
drift_06() {
  local queue sub
  queue=$(cfn_resource drift-test-06 DriftTestQueue)
  sub=$(cfn_resource drift-test-06 TopicSubscription)
  log "[06] SNS/SQS — queue attributes + subscription drift"

  local vis=120 retention=345600   # 2min, 4 days
  [[ "$ROUND" -eq 2 ]] && vis=300  && retention=604800   # 5min, 7 days
  [[ "$ROUND" -eq 3 ]] && vis=600  && retention=1209600  # 10min, 14 days
  aws sqs set-queue-attributes --region "$REGION" --queue-url "$queue" \
    --attributes "{\"VisibilityTimeout\":\"${vis}\",\"MessageRetentionPeriod\":\"${retention}\"}"
  ok "[06] SQS VisibilityTimeout 60 → ${vis}s, retention → ${retention}s"

  aws sns set-subscription-attributes --region "$REGION" \
    --subscription-arn "$sub" \
    --attribute-name RawMessageDelivery \
    --attribute-value false
  ok "[06] RawMessageDelivery true → false on subscription"
}

# ── Stack 07: VPC ─────────────────────────────────────────────────────────────
# Drift: disable MapPublicIpOnLaunch on public subnet; add tags to VPC
drift_07() {
  local vpc subnet_a
  vpc=$(cfn_resource drift-test-07 DriftTestVPC)
  subnet_a=$(cfn_resource drift-test-07 PublicSubnetA)
  log "[07] VPC — subnet attribute + VPC tag drift"

  aws ec2 modify-subnet-attribute --region "$REGION" \
    --subnet-id "$subnet_a" \
    --no-map-public-ip-on-launch
  ok "[07] MapPublicIpOnLaunch disabled on $subnet_a"

  aws ec2 create-tags --region "$REGION" \
    --resources "$vpc" \
    --tags "Key=DriftInduced,Value=true" "Key=Round,Value=${ROUND}"
  ok "[07] DriftInduced+Round tags added to VPC $vpc"
}

# ── Stack 08: EC2 Instance ────────────────────────────────────────────────────
# Drift: enable detailed monitoring (template: false); add SG ingress rule
drift_08() {
  local instance sg
  instance=$(cfn_resource drift-test-08 DriftTestInstance)
  sg=$(cfn_resource drift-test-08 InstanceSG)
  log "[08] EC2 — monitoring + security group drift on $instance"

  aws ec2 monitor-instances --region "$REGION" \
    --instance-ids "$instance" > /dev/null
  ok "[08] Detailed monitoring false → true on $instance"

  local cidr="10.0.0.0/8"
  [[ "$ROUND" -eq 2 ]] && cidr="172.16.0.0/12"
  [[ "$ROUND" -eq 3 ]] && cidr="192.168.0.0/16"
  if aws ec2 authorize-security-group-ingress --region "$REGION" \
      --group-id "$sg" \
      --protocol tcp --port 80 --cidr "$cidr" 2>/dev/null; then
    ok "[08] Added port 80/$cidr ingress to $sg"
  else
    skip "[08] Port 80 rule for $cidr already exists on $sg"
  fi
}

# ── Stack 09: CloudWatch ──────────────────────────────────────────────────────
# Drift: raise alarm thresholds; extend log retention
drift_09() {
  local log_group
  log_group=$(cfn_resource drift-test-09 AppLogGroup)
  log "[09] CloudWatch — alarm thresholds + log retention drift"

  local thresh_low=10 thresh_high=50
  [[ "$ROUND" -eq 2 ]] && thresh_low=25  && thresh_high=100
  [[ "$ROUND" -eq 3 ]] && thresh_low=50  && thresh_high=200

  aws cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name drift-test-09-error-rate \
    --namespace DriftTest \
    --metric-name ErrorCount \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold "$thresh_low" \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching
  ok "[09] ErrorRateAlarm threshold 5 → $thresh_low"

  aws cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name drift-test-09-high-error-rate \
    --namespace DriftTest \
    --metric-name ErrorCount \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 2 \
    --datapoints-to-alarm 2 \
    --threshold "$thresh_high" \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching
  ok "[09] HighErrorRateAlarm threshold 20 → $thresh_high"

  local retention=30
  [[ "$ROUND" -eq 2 ]] && retention=60
  [[ "$ROUND" -eq 3 ]] && retention=90
  aws logs put-retention-policy --region "$REGION" \
    --log-group-name "$log_group" --retention-in-days "$retention"
  ok "[09] Log retention 14 → ${retention} days on $log_group"
}

# ── Stack 10: Event Pipeline ──────────────────────────────────────────────────
# Drift: Lambda timeout+memory; queue visibility timeout; DLQ retention; alarm threshold; log retention
drift_10() {
  local fn queue dlq dlq_name log_group
  fn=$(cfn_resource drift-test-10 ProcessorFunction)
  queue=$(cfn_resource drift-test-10 ProcessingQueue)
  dlq=$(cfn_resource drift-test-10 DeadLetterQueue)
  dlq_name=$(basename "$dlq")
  log_group=$(cfn_resource drift-test-10 ProcessorLogGroup)
  log "[10] Event Pipeline — Lambda/SQS/alarm/log drift"

  local timeout=120 memory=512
  [[ "$ROUND" -eq 2 ]] && timeout=180 && memory=1024
  [[ "$ROUND" -eq 3 ]] && timeout=300 && memory=2048
  aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$fn" \
    --timeout "$timeout" \
    --memory-size "$memory" \
    > /dev/null
  ok "[10] Lambda timeout 60 → ${timeout}s, memory 256 → ${memory}MB on $fn"

  local vis=600
  [[ "$ROUND" -eq 2 ]] && vis=900
  [[ "$ROUND" -eq 3 ]] && vis=1200
  aws sqs set-queue-attributes --region "$REGION" --queue-url "$queue" \
    --attributes "{\"VisibilityTimeout\":\"${vis}\"}"
  ok "[10] ProcessingQueue VisibilityTimeout 300 → ${vis}s"

  aws sqs set-queue-attributes --region "$REGION" --queue-url "$dlq" \
    --attributes '{"MessageRetentionPeriod":"345600"}'
  ok "[10] DeadLetterQueue retention 14 days → 4 days"

  local dlq_threshold=5
  [[ "$ROUND" -eq 2 ]] && dlq_threshold=10
  [[ "$ROUND" -eq 3 ]] && dlq_threshold=25
  aws cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name drift-test-10-dlq-depth \
    --namespace AWS/SQS \
    --metric-name ApproximateNumberOfMessagesVisible \
    --dimensions "Name=QueueName,Value=${dlq_name}" \
    --statistic Maximum \
    --period 60 \
    --evaluation-periods 1 \
    --threshold "$dlq_threshold" \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching
  ok "[10] DLQDepthAlarm threshold 1 → $dlq_threshold"

  local retention=30
  [[ "$ROUND" -eq 2 ]] && retention=60
  [[ "$ROUND" -eq 3 ]] && retention=90
  aws logs put-retention-policy --region "$REGION" \
    --log-group-name "$log_group" --retention-in-days "$retention"
  ok "[10] ProcessorLogGroup retention 14 → ${retention} days"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "================================================"
  log "  Drift Inducer"
  log "  Region : $REGION"
  log "  Round  : $ROUND"
  log "  Log    : $LOG_FILE"
  log "================================================"

  local start
  start=$(date +%s)

  drift_01 &
  drift_02 &
  drift_03 &
  drift_04 &
  drift_05 &
  drift_06 &
  drift_07 &
  drift_08 &
  drift_09 &
  drift_10 &
  wait

  local elapsed=$(( $(date +%s) - start ))
  local count
  count=$(ls "$COUNTER_DIR" | wc -l | tr -d ' ')

  log "================================================"
  log "  Completed in ${elapsed}s — ${count} changes applied across 10 stacks"
  log "  Full log: $LOG_FILE"
  log "================================================"
}

main
