# GitHub Actions auth via Workload Identity Federation (keyless).
# GCP analog of the AWS github-oidc.tf. Apply this via LOCAL admin credentials.
#
# The apply service account below is deliberately NOT granted permission to
# create or modify this pool, the provider, or these service accounts — same
# "no IAM self-modification" rule as the AWS apply role. It only gets IAM
# *read* (via roles/viewer) so `terraform apply` can refresh their state; any
# real change to this file must be applied locally.
#
# Scoping model (mirrors the AWS roles):
#   - provider attribute_condition pins the whole pool to THIS repo.
#   - deploy SAs (push/apply/frontend) are further pinned to a specific
#     reusable workflow file via job_workflow_ref, on the dev branch (GCP is
#     the "dev" environment).
#   - the plan SA is scoped to the pull_request event only (read-only, so the
#     looser event-level scope is acceptable — same as the AWS plan role).

#----------------------------------------------------------
# Workload Identity Pool + GitHub OIDC provider
#----------------------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for GitHub Actions in ${var.github_repo}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
    "attribute.event_name"       = "assertion.event_name"
  }

  # Required by GCP (a provider mapping google.subject must carry a condition)
  # and security-critical: only tokens issued to this repo can use the pool.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  pool_name = google_iam_workload_identity_pool.github.name

  # Reusable-workflow job_workflow_ref values, pinned to the dev branch.
  # These filenames are load-bearing — the 4b workflows must match them.
  wf_push     = "${var.github_repo}/.github/workflows/reusable-gcp-build-push.yml@refs/heads/dev"
  wf_apply    = "${var.github_repo}/.github/workflows/reusable-gcp-tf-apply.yml@refs/heads/dev"
  wf_frontend = "${var.github_repo}/.github/workflows/reusable-gcp-frontend.yml@refs/heads/dev"

  # State bucket from the bootstrap stack (referenced by name — different stack).
  state_bucket = "${var.project_id}-tfstate"

  # Cloud Run's default runtime SA (Compute Engine default). The apply SA needs
  # actAs on it to deploy the service.
  runtime_sa = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

#----------------------------------------------------------
# Push SA — builds land in Artifact Registry. AR writer only.
#----------------------------------------------------------

resource "google_service_account" "gha_push" {
  account_id   = "gha-gcp-push"
  display_name = "GitHub Actions - build & push (GCP)"
}

resource "google_service_account_iam_member" "gha_push_wif" {
  service_account_id = google_service_account.gha_push.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.job_workflow_ref/${local.wf_push}"
}

resource "google_artifact_registry_repository_iam_member" "gha_push_writer" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.gha_push.email}"
}

#----------------------------------------------------------
# Plan SA — read-only against the project + state bucket (for the lock object).
# Scoped to the pull_request event, like the AWS plan role.
#----------------------------------------------------------

resource "google_service_account" "gha_plan" {
  account_id   = "gha-gcp-plan"
  display_name = "GitHub Actions - terraform plan (GCP)"
}

resource "google_service_account_iam_member" "gha_plan_wif" {
  service_account_id = google_service_account.gha_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.event_name/pull_request"
}

resource "google_project_iam_member" "gha_plan_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.gha_plan.email}"
}

# GCS backend writes a lock object even during plan, so objectUser (read + the
# lock write), not just viewer.
resource "google_storage_bucket_iam_member" "gha_plan_state" {
  bucket = local.state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.gha_plan.email}"
}

#----------------------------------------------------------
# Frontend SA — Firebase Hosting deploys only. Never touches infra.
#----------------------------------------------------------

resource "google_service_account" "gha_frontend" {
  account_id   = "gha-gcp-frontend"
  display_name = "GitHub Actions - frontend deploy (GCP)"
}

resource "google_service_account_iam_member" "gha_frontend_wif" {
  service_account_id = google_service_account.gha_frontend.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.job_workflow_ref/${local.wf_frontend}"
}

resource "google_project_iam_member" "gha_frontend_hosting" {
  project = var.project_id
  role    = "roles/firebasehosting.admin"
  member  = "serviceAccount:${google_service_account.gha_frontend.email}"
}

#----------------------------------------------------------
# Apply SA — infra CRUD for this stack. Scoped roles, no IAM self-modification.
#----------------------------------------------------------

resource "google_service_account" "gha_apply" {
  account_id   = "gha-gcp-apply"
  display_name = "GitHub Actions - terraform apply (GCP)"
}

resource "google_service_account_iam_member" "gha_apply_wif" {
  service_account_id = google_service_account.gha_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.job_workflow_ref/${local.wf_apply}"
}

# Project-level roles the stack actually mutates.
resource "google_project_iam_member" "gha_apply_roles" {
  for_each = toset([
    "roles/viewer",                        # read everything (incl. WIF/SA) for state refresh
    "roles/run.admin",                     # Cloud Run service
    "roles/artifactregistry.admin",        # the AR repo resource
    "roles/monitoring.editor",             # budget notification channel
    "roles/serviceusage.serviceUsageAdmin" # google_project_service enablement
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gha_apply.email}"
}

# actAs on the Cloud Run runtime SA (required to deploy the service).
resource "google_service_account_iam_member" "gha_apply_runtime_actas" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.runtime_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.gha_apply.email}"
}

resource "google_storage_bucket_iam_member" "gha_apply_state" {
  bucket = local.state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.gha_apply.email}"
}

# ACCOUNT-WIDE GRANT — flagged for review.
# The budget (budget.tf) is a billing-account resource, so managing it requires
# a role on the whole billing account, not just this project. This mirrors the
# AWS apply role's `budgets:*`. If you'd rather not grant a CI SA account-wide
# budget management, move budget.tf to a locally-applied file and delete this.
resource "google_billing_account_iam_member" "gha_apply_budgets" {
  billing_account_id = var.billing_account
  role               = "roles/billing.costsManager"
  member             = "serviceAccount:${google_service_account.gha_apply.email}"
}
