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

variable "backend_enabled" {
  description = <<-EOT
    On/off switch for the pay-per-hour backend tier: the ALB, the ECS/Fargate
    service, the three interface VPC endpoints, and the CloudFront VPC origin +
    /api/* behavior (~$69/mo running). false = the dormant ~$0/mo state — only
    free/near-free resources remain, the static site still loads, and /api/*
    calls surface the app's built-in "backend unreachable" state. Flip it in a
    PR to spin the backend up or down through the GitOps apply.

    NOTE: this is the *application* backend — unrelated to the Terraform state
    backend configured in backend.tf.
  EOT
  type        = bool
  default     = false
}

variable "retain_backend_origin" {
  description = <<-EOT
    Teardown-ordering escape hatch — leave this false in committed config.

    A CloudFront VPC origin can't be deleted while the distribution still
    references it, and Terraform won't order the distribution's in-place update
    (dropping the origin) ahead of the origin's destroy in a single apply, so a
    plain `terraform apply` on a backend_enabled true->false diff wedges with
    409 CannotDeleteEntityWhileInUse. scripts/aws-safe-apply.sh (and CI) work
    around it with two applies: the first sets this true so the distribution
    detaches from the VPC origin while the origin (and the ALB/IGW it needs)
    stay alive; the second, with this back to false, deletes the now-orphaned
    origin cleanly. See the note above aws_cloudfront_vpc_origin.alb in edge.tf.
  EOT
  type        = bool
  default     = false
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
