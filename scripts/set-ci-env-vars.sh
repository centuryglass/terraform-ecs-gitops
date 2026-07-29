#!/usr/bin/env bash
#
# set-ci-env-vars.sh — sync a GitHub Actions Environment's variables from the
# current Terraform outputs of the matching stack. Non-secret config only (role
# ARNs / service-account emails, bucket + registry names, region, etc.). Prints
# a diff and asks [y/N] before writing anything.
#
# Usage:
#   scripts/set-ci-env-vars.sh prod-aws   # infra/prod-aws  -> GitHub env "prod"
#   scripts/set-ci-env-vars.sh dev-gcp    # infra/dev-gcp   -> GitHub env "dev"
#
# Requires: gh (authenticated), terraform (backend initialized for the stack).
# The AWS stack reads its S3-backed state, so it needs AWS creds — defaults to
# AWS_PROFILE=devops-test unless AWS_PROFILE is already set.
#
# Design note: each environment branch only *builds the desired KEY=VALUE set*
# (via set_var). Everything after the case — reading current values, diffing,
# confirming, writing — is generic, so the two very different environments stay
# in one script without tangled branching.

set -euo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

require_cmd gh
require_cmd terraform

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
cd "$REPO_ROOT"

# tf_out <stack-dir> <output-name> — raw terraform output from the stack's state.
tf_out() {
  terraform -chdir="$1" output -raw "$2" 2>/dev/null \
    || die "could not read terraform output '$2' from $1 (backend initialized? creds set?)"
}

ENV_ARG="${1:-}"

# Filled per environment; VAR_NAMES preserves display order, DESIRED holds values.
VAR_NAMES=()
declare -A DESIRED=()
set_var() { VAR_NAMES+=("$1"); DESIRED["$1"]="$2"; }

case "$ENV_ARG" in
  prod-aws)
    GH_ENV="prod"
    STACK="infra/prod-aws"
    export AWS_PROFILE="${AWS_PROFILE:-devops-test}"

    ecr_url="$(tf_out "$STACK" ecr_repository_url)"

    set_var AWS_REGION         "us-east-1"
    set_var TF_DIR             "$STACK"
    set_var ECR_REPO           "${ecr_url##*/}"
    set_var ROLE_PUSH          "$(tf_out "$STACK" push_role_arn_github)"
    set_var ROLE_PLAN          "$(tf_out "$STACK" plan_role_arn_github)"
    set_var ROLE_APPLY         "$(tf_out "$STACK" apply_role_arn_github)"
    set_var ROLE_FRONTEND      "$(tf_out "$STACK" frontend_deploy_role_arn_github)"
    set_var FRONTEND_BUCKET    "$(tf_out "$STACK" frontend_bucket_name)"
    set_var CLOUDFRONT_DIST_ID "$(tf_out "$STACK" cloudfront_distribution_id)"
    ;;

  dev-gcp)
    GH_ENV="dev"
    STACK="infra/dev-gcp"

    # region / project / repo all fall out of the one AR output string, e.g.
    #   us-central1-docker.pkg.dev/waypoint-live-0857/waypoint-imgs
    ar="$(tf_out "$STACK" artifact_registry_repo)"
    gcp_region="${ar%%-docker.pkg.dev*}"
    ar_rest="${ar#*-docker.pkg.dev/}"
    gcp_project="${ar_rest%%/*}"
    ar_repo="${ar_rest##*/}"

    # IMAGE_NAME is the image basename (sans tag) from the CI-managed tfvars.
    img_ref="$(grep -oP '(?<=image = ")[^"]+' "$STACK/image.auto.tfvars" 2>/dev/null || true)"
    [ -n "$img_ref" ] || die "could not read image from $STACK/image.auto.tfvars"
    img_no_tag="${img_ref%:*}"

    set_var TF_DIR       "$STACK"
    set_var GCP_REGION   "$gcp_region"
    set_var GCP_PROJECT  "$gcp_project"
    set_var AR_REPO      "$ar_repo"
    set_var IMAGE_NAME   "${img_no_tag##*/}"
    set_var WIF_PROVIDER "$(tf_out "$STACK" wif_provider)"
    set_var SA_PUSH      "$(tf_out "$STACK" sa_push_email)"
    set_var SA_PLAN      "$(tf_out "$STACK" sa_plan_email)"
    set_var SA_APPLY     "$(tf_out "$STACK" sa_apply_email)"
    set_var SA_FRONTEND  "$(tf_out "$STACK" sa_frontend_email)"

    # BILLING_ACCOUNT is mildly sensitive and deliberately NOT a TF output; it
    # lives in the gitignored terraform.tfvars. Set it if present, otherwise
    # leave whatever is already on the environment untouched.
    billing="$(grep -E '^[[:space:]]*billing_account[[:space:]]*=' "$STACK/terraform.tfvars" 2>/dev/null \
                 | grep -oP '"\K[^"]+' || true)"
    if [ -n "$billing" ]; then
      set_var BILLING_ACCOUNT "$billing"
    else
      printf 'note: BILLING_ACCOUNT not found in %s/terraform.tfvars — leaving it as-is.\n\n' "$STACK" >&2
    fi
    ;;

  *)
    cat >&2 <<EOF
usage: ${0##*/} <prod-aws|dev-gcp>

  prod-aws   sync infra/prod-aws    outputs -> GitHub Environment "prod"
  dev-gcp    sync infra/dev-gcp     outputs -> GitHub Environment "dev"

Reads current terraform outputs, shows a diff against the environment's current
variables, and writes only after you confirm [y/N].
EOF
    exit 1
    ;;
esac

# Current values (Actions *variables* are non-secret, so their values are
# readable). If the field is unavailable for any reason we fall back to empty,
# which just makes everything show as an add — still correct, just noisier.
declare -A CURRENT=()
while IFS=$'\t' read -r _name _value; do
  [ -n "$_name" ] && CURRENT["$_name"]="$_value"
done < <(gh variable list --env "$GH_ENV" --json name,value \
           --jq '.[] | [.name, .value] | @tsv' 2>/dev/null || true)

# Build + display the change set.
CHANGED=()
printf '\nGitHub Environment: %s\n' "$GH_ENV"
printf 'Source stack:       %s\n\n' "$STACK"
for name in "${VAR_NAMES[@]}"; do
  desired="${DESIRED[$name]}"
  if [ -z "${CURRENT[$name]+x}" ]; then
    printf '  + %-20s %s\n' "$name" "$desired"
    CHANGED+=("$name")
  elif [ "${CURRENT[$name]}" != "$desired" ]; then
    printf '  ~ %-20s %s -> %s\n' "$name" "${CURRENT[$name]}" "$desired"
    CHANGED+=("$name")
  else
    printf '    %-20s %s (unchanged)\n' "$name" "$desired"
  fi
done

if [ "${#CHANGED[@]}" -eq 0 ]; then
  printf '\nNothing to do — all variables already match.\n'
  exit 0
fi

printf '\n%d variable(s) to write  (+ add, ~ change).\n' "${#CHANGED[@]}"
read -r -p "Apply to the \"$GH_ENV\" environment? [y/N] " reply
case "$reply" in
  [yY] | [yY][eE][sS]) ;;
  *) printf 'Aborted; nothing written.\n'; exit 0 ;;
esac

for name in "${CHANGED[@]}"; do
  gh variable set "$name" --env "$GH_ENV" --body "${DESIRED[$name]}"
  printf '  set %s\n' "$name"
done
printf 'Done.\n'
