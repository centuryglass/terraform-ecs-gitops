variable "project_id" {
  description = "GCP project ID for the live-demo environment."
  type        = string
  default     = "waypoint-live-0857"
}

variable "region" {
  description = "Region for Cloud Run + Artifact Registry. us-central1 keeps Cloud Run in the free tier and matches the Firebase Hosting rewrite default."
  type        = string
  default     = "us-central1"
}

variable "image" {
  description = <<-EOT
    Full container image reference for the Cloud Run service. Defaults to
    Google's public "hello" sample so the first apply produces a working,
    curlable URL before any real image exists. CI (Phase 4) will point this at
    the Artifact Registry image via image.auto.tfvars, mirroring the AWS side.
  EOT
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "container_port" {
  description = "Port the app listens on. Cloud Run injects this as the PORT env var, which the app reads (same contract as the AWS task)."
  type        = number
  default     = 8080
}

variable "alert_email" {
  description = "Email address for the GCP budget threshold alerts."
  type        = string
  default     = "anthony0857@gmail.com"
}

variable "billing_account" {
  description = "Billing account ID (form XXXXXX-XXXXXX-XXXXXX) the project is linked to. Required for the budget. Set in terraform.tfvars; find it with `gcloud billing accounts list`."
  type        = string
}

variable "github_repo" {
  description = "owner/repo — scopes the WIF attribute condition and the per-workflow service-account bindings."
  type        = string
  default     = "centuryglass/terraform-ecs-gitops"
}
