terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
  }
  required_version = ">= 1.15"
}

# Define instance suffix as something like "-test" if you want to spin up
# an alternate set of named resources. Leave blank by default.
locals {
  instance_suffix = ""

  # The CloudFront VPC origin and the ALB it points at must survive a detach-only
  # apply (retain_backend_origin) so the origin can be disassociated from the
  # distribution before it's destroyed. See variable "retain_backend_origin" and
  # scripts/aws-safe-apply.sh.
  vpc_origin_alive = var.backend_enabled || var.retain_backend_origin
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { app = format("waypoint-web%s", local.instance_suffix) }
  }
}


#----------------------------------------------------------
# Resource group
#----------------------------------------------------------

resource "aws_resourcegroups_group" "waypoint_web_group" {
  name        = format("waypoint-web-group%s", local.instance_suffix)
  description = "Resource group for all waypoint infrastructure"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]

      TagFilters = [
        {
          Key    = "app"
          Values = ["waypoint-web"]
        }
      ]
    })
  }
}
