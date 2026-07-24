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
  description = "Port the Haskell app listens on inside the container (matches the PORT env var it reads)."
  type        = number
  default     = 8080
}

variable "github_repo" {
  description = "GitHub org/repo,used to scope the OIDC trust policies so only this repo's workflows can assume the roles."
  type        = string
  default     = "centuryglass/terraform-ecs-gitops"
}

variable "alert_email" {
  description = "Email address for AWS Budget threshold alerts."
  type        = string
  default     = "anthony0857@gmail.com"
}
