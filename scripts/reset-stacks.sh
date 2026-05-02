#!/usr/bin/env bash
# reset-stacks.sh
#
# Destroys all 10 drift-test stacks and redeploys them from the local templates,
# restoring every stack to its CloudFormation-defined state.
#
# Execution order:
#   Phase 1 — Delete all 10 stacks in parallel, wait for completion.
#   Phase 2a — Deploy independent stacks in parallel (01-03, 05-07, 09-10).
#   Phase 2b — Fetch VPC outputs from drift-test-07.
#   Phase 2c — Deploy VPC-dependent stacks in parallel (04, 08).
#
# Usage:
#   ./scripts/reset-stacks.sh
#
# Prerequisites: AWS CLI configured with credentials for terraform-iam-user.

set -uo pipefail

REGION="us-east-1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${REPO_ROOT}/reset-run-${TIMESTAMP}.log"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
ok()   { log "  OK   $*"; }
err()  { log "  ERR  $*"; }

template_path() {
  case "$1" in
    01) echo "stacks/01-s3-basic/template.yaml" ;;
    02) echo "stacks/02-s3-advanced/template.yaml" ;;
    03) echo "stacks/03-iam-role/template.yaml" ;;
    04) echo "stacks/04-security-groups/template.yaml" ;;
    05) echo "stacks/05-lambda/template.yaml" ;;
    06) echo "stacks/06-sns-sqs/template.yaml" ;;
    07) echo "stacks/07-vpc-networking/template.yaml" ;;
    08) echo "stacks/08-ec2-instance/template.yaml" ;;
    09) echo "stacks/09-cloudwatch/template.yaml" ;;
    10) echo "stacks/10-event-pipeline/template.yaml" ;;
  esac
}

cfn_output() {
  aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text
}

# ── Phase 1: Delete ───────────────────────────────────────────────────────────

delete_stack() {
  local name="drift-test-$1"
  log "Deleting $name..."

  aws cloudformation delete-stack \
    --region "$REGION" --stack-name "$name" 2>/dev/null || true

  if aws cloudformation wait stack-delete-complete \
      --region "$REGION" --stack-name "$name" 2>/dev/null; then
    ok "Deleted $name"
  else
    # wait returns non-zero when the stack no longer exists — confirm actual state
    local status
    status=$(aws cloudformation describe-stacks \
      --region "$REGION" --stack-name "$name" \
      --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DELETED")
    if [[ "$status" == "DELETED" || -z "$status" ]]; then
      ok "Deleted $name"
    else
      err "Failed to delete $name (status: $status) — check CloudFormation console"
    fi
  fi
}

# ── Phase 2: Deploy ───────────────────────────────────────────────────────────

deploy_stack() {
  local num="$1"
  local name="drift-test-${num}"
  local template="${REPO_ROOT}/$(template_path "$num")"
  shift  # remaining positional args are parameter override key=value pairs

  log "Deploying $name..."

  local cmd=(
    aws cloudformation deploy
    --region "$REGION"
    --template-file "$template"
    --stack-name "$name"
    --capabilities CAPABILITY_NAMED_IAM
    --no-fail-on-empty-changeset
  )
  [[ $# -gt 0 ]] && cmd+=(--parameter-overrides "$@")

  if "${cmd[@]}"; then
    ok "Deployed $name"
  else
    err "Failed to deploy $name — check CloudFormation console for details"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  log "================================================"
  log "  Stack Reset"
  log "  Region : $REGION"
  log "  Log    : $LOG_FILE"
  log "================================================"

  local start
  start=$(date +%s)

  # ── Phase 1: Delete all 10 stacks in parallel ─────────────────────────────
  log ""
  log "Phase 1 — Deleting all stacks in parallel..."
  log ""

  for num in 01 02 03 04 05 06 07 08 09 10; do
    delete_stack "$num" &
  done
  wait

  log ""
  log "All stacks deleted."

  # ── Phase 2a: Deploy independent stacks in parallel ───────────────────────
  log ""
  log "Phase 2a — Deploying independent stacks (01-03, 05-07, 09-10)..."
  log ""

  for num in 01 02 03 05 06 07 09 10; do
    deploy_stack "$num" &
  done
  wait

  # ── Phase 2b: Fetch VPC outputs from stack 07 ─────────────────────────────
  local vpc_id subnet_id
  vpc_id=$(cfn_output drift-test-07 VpcId)
  subnet_id=$(cfn_output drift-test-07 PublicSubnetAId)

  if [[ -z "$vpc_id" || -z "$subnet_id" ]]; then
    err "Could not fetch VPC outputs from drift-test-07 — skipping stacks 04 and 08"
  else
    log ""
    log "  VpcId=$vpc_id  SubnetId=$subnet_id"

    # ── Phase 2c: Deploy VPC-dependent stacks in parallel ─────────────────
    log ""
    log "Phase 2c — Deploying VPC-dependent stacks (04, 08)..."
    log ""

    deploy_stack 04 "VpcId=${vpc_id}" &
    deploy_stack 08 "VpcId=${vpc_id}" "SubnetId=${subnet_id}" &
    wait
  fi

  local elapsed=$(( $(date +%s) - start ))
  local ok_count err_count
  ok_count=$(grep -c '  OK   ' "$LOG_FILE" || true)
  err_count=$(grep -c '  ERR  ' "$LOG_FILE" || true)

  log ""
  log "================================================"
  log "  Completed in ${elapsed}s"
  log "  OK: ${ok_count}  ERR: ${err_count}"
  log "  Full log: $LOG_FILE"
  log "================================================"
}

main
