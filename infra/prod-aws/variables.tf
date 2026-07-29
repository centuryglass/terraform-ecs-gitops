data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

variable "image_tag" {
  description = "Tag of the container image to deploy. Auto-updated by CI via image.auto.tfvars once the pipeline exists."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the app listens on inside the container (matches the PORT env var it reads)."
  type        = number
  default     = 8080
}

variable "github_repo" {
  description = "GitHub org/repo,used to scope the job_workflow_ref condition in the OIDC trust policies. That claim is unaffected by subject-claim customization (see github_oidc_subject_prefix) and always uses this plain owner/repo form."
  type        = string
  default     = "centuryglass/terraform-ecs-gitops"
}

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    The stable prefix GitHub uses to build the OIDC "sub" claim for this repo.
    As of GitHub's current default subject-claim format, this embeds the
    immutable owner and repository IDs (not just their names), so it won't
    match a plain "repo:owner/repo" string. Fetch the current value for any
    repo with:
      gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string
  default     = "repo:centuryglass@15644092/terraform-ecs-gitops@1312345750"
}

variable "alert_email" {
  description = "Email address for AWS Budget threshold alerts."
  type        = string
  default     = "anthony0857@gmail.com"
}
