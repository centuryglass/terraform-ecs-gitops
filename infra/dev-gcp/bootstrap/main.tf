# Bootstraps the GCS bucket that holds Terraform state for the GCP "live demo"
# stack (infra/dev-gcp). GCP-side analog of infra/bootstrap. Applied manually,
# once — not part of CI. Re-run only if the state bucket needs to change.

#----------------------------------------------------------
# Basic config
#----------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  required_version = ">= 1.15"
}

variable "project_id" {
  description = "GCP project ID for the live-demo environment."
  type        = string
  default     = "waypoint-live-0857"
}

variable "region" {
  description = "Default region. us-central1 keeps Cloud Run in the free tier and matches the Firebase Hosting rewrite default."
  type        = string
  default     = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

#----------------------------------------------------------
# GCS bucket holding terraform state
#----------------------------------------------------------

resource "google_storage_bucket" "terraform_state" {
  name     = "${var.project_id}-tfstate" # bucket names are globally unique; the project ID already is
  location = "US"                        # multi-region for state durability; contents are tiny (KBs)

  # Versioning so we can revert a bad state write, mirroring the S3 bootstrap.
  versioning {
    enabled = true
  }

  # Lock down access: no ACLs, no public exposure. Equivalent to the S3
  # public-access-block on the AWS side.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # No force_destroy: refuse to delete a non-empty state bucket by accident.
  lifecycle {
    prevent_destroy = true
  }
}

#----------------------------------------------------------
# Auto-generate backend.tf for the main stack on bootstrap
#----------------------------------------------------------

#----------------------------------------------------------
# CI state access
# The plan/apply service accounts (defined in the main stack's github-oidc.tf)
# need read/write on this bucket for the Terraform GCS backend. Granting it here
# — where the bucket lives — keeps the CI-applied main stack from having to
# manage, and therefore read, this bucket's IAM policy. Referenced by
# deterministic email since the SAs live in the other stack; apply this after
# that stack has created them.
#----------------------------------------------------------

resource "google_storage_bucket_iam_member" "ci_plan_state" {
  bucket = google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:gha-gcp-plan@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "ci_apply_state" {
  bucket = google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:gha-gcp-apply@${var.project_id}.iam.gserviceaccount.com"
}

resource "local_file" "backend_config" {
  filename = "${path.module}/../backend.tf"
  content  = <<-EOF
    terraform {
      backend "gcs" {
        bucket = "${google_storage_bucket.terraform_state.name}"
        prefix = "waypoint/dev-gcp"
      }
    }
  EOF
}
