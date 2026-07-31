#!/usr/bin/env bash
#
# aws-safe-apply.sh — `terraform apply` for the AWS stack that survives a
# CloudFront VPC-origin teardown.
#
# The problem it solves:
#   A CloudFront VPC origin can't be deleted while a distribution still
#   references it. When you flip backend_enabled to false, Terraform plans BOTH
#   "update the distribution to drop the alb-backend origin" AND "destroy the
#   VPC origin" — but in a single apply it fires DeleteVpcOrigin before the
#   distribution update has committed, so AWS returns
#     409 CannotDeleteEntityWhileInUse
#   the run aborts, and the distribution update never lands. Every retry then
#   starts from the same stuck state, so re-applying (even hours later) never
#   clears it. Terraform doesn't reliably order the distribution update ahead of
#   the origin delete on its own. See the note above aws_cloudfront_vpc_origin.alb
#   in edge.tf.
#
# What it does:
#   Plans first. If the plan would delete or replace the VPC origin, it applies
#   the distribution change on its own (-target) to disassociate the origin,
#   then runs the full apply that deletes it. Otherwise it applies the plan
#   normally, so it's a safe drop-in for `terraform apply` on every run, not
#   just teardowns.
#
# Usage:
#   scripts/aws-safe-apply.sh                 # interactive, prompts to confirm
#   scripts/aws-safe-apply.sh -auto-approve   # non-interactive (what CI runs)
#   scripts/aws-safe-apply.sh -no-color       # pass -no-color through to Terraform
#   TF_DIR=infra/prod-aws scripts/aws-safe-apply.sh   # override the stack dir
#
# Requires: terraform, jq (both present on GitHub's ubuntu-latest runners).

set -euo pipefail

VPC_ORIGIN_TYPE="aws_cloudfront_vpc_origin"

auto_approve=false
tf_flags=()
for arg in "$@"; do
  case "$arg" in
    -auto-approve) auto_approve=true ;;
    -no-color)     tf_flags+=(-no-color) ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: required command '$cmd' not found" >&2; exit 1; }
done

TF_DIR="${TF_DIR:-infra/prod-aws}"
REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "error: not inside a git repository" >&2; exit 1; }
cd "$REPO_ROOT/$TF_DIR" || { echo "error: stack dir not found: $TF_DIR" >&2; exit 1; }

plan_file="$(mktemp)"
plan_json="$(mktemp)"
trap 'rm -f "$plan_file" "$plan_json"' EXIT

echo "==> terraform init"
terraform init -input=false "${tf_flags[@]}"

echo "==> terraform plan"
terraform plan -input=false -out="$plan_file" "${tf_flags[@]}"
terraform show -json "$plan_file" >"$plan_json"

# Does this plan delete (or replace) the CloudFront VPC origin? A "delete"
# action covers both a pure destroy and the delete half of a replace — both hit
# the 409 unless the distribution drops its reference first.
teardown=false
if jq -e --arg t "$VPC_ORIGIN_TYPE" \
     'any(.resource_changes[]?; .type == $t and (.change.actions | index("delete")))' \
     "$plan_json" >/dev/null; then
  teardown=true
fi

if ! $auto_approve; then
  if $teardown; then
    echo
    echo "This plan deletes the CloudFront VPC origin. It will be applied in two"
    echo "phases: first the distribution is detached from the origin (keeping the"
    echo "origin alive), then the now-orphaned origin is deleted."
  fi
  read -r -p "Apply these changes? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Aborted."; exit 1; }
fi

if $teardown; then
  # Phase 1: retain_backend_origin=true keeps the VPC origin (and the ALB it
  # points at) alive while the distribution drops its reference to the origin.
  # This detaches them in one apply without deleting the origin, so no 409.
  echo "==> Phase 1/2: terraform apply -var retain_backend_origin=true (detach VPC origin from distribution)"
  terraform apply -input=false -auto-approve "${tf_flags[@]}" -var retain_backend_origin=true
  # Phase 2: with retain_backend_origin back to its default (false), the now
  # unreferenced VPC origin deletes cleanly. The saved plan is stale after phase
  # 1, so re-plan implicitly with a plain apply.
  echo "==> Phase 2/2: terraform apply (delete the now-orphaned VPC origin + remaining changes)"
  terraform apply -input=false -auto-approve "${tf_flags[@]}"
else
  # No VPC-origin teardown: apply exactly the plan we just showed/approved.
  echo "==> terraform apply"
  terraform apply -input=false "${tf_flags[@]}" "$plan_file"
fi

echo "==> terraform output"
terraform output
