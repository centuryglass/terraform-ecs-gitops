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
  description = "Resource group for all waypoint-web infrastructure"

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

#----------------------------------------------------------
# Container registry + cluster
#----------------------------------------------------------

resource "aws_ecr_repository" "container_registry" {
  name                 = format("waypoint-build-imgs%s", local.instance_suffix)
  image_tag_mutability = "IMMUTABLE"
}

resource "aws_ecs_cluster" "container_cluster" {
  name = format("waypoint-ecs%s", local.instance_suffix)
}

#----------------------------------------------------------
# Custom VPC — private subnets + VPC endpoints (no NAT)
# Standalone for now: validates ECR pull + log write from a private
# subnet before ALB/ECS actually move into it (step 3 of the plan).
#----------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "custom" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = format("waypoint-vpc%s", local.instance_suffix)
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.custom.id
  cidr_block        = cidrsubnet(aws_vpc.custom.cidr_block, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = format("waypoint-private-%s%s", count.index, local.instance_suffix)
  }
}

# Local-only route table — no IGW, no NAT route. The S3 gateway endpoint
# association below adds the prefix-list route needed for ECR layer pulls.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.custom.id

  tags = {
    Name = format("waypoint-private-rt%s", local.instance_suffix)
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# SG for the interface endpoints. Using the VPC CIDR here rather than a
# security-group reference — SG-to-SG references only work within the
# same VPC, and the ECS task SG still lives in the default VPC at this
# point in the migration. Revisit once ECS tasks actually run in `custom`.
resource "aws_security_group" "vpc_endpoints" {
  name        = format("waypoint-vpce-sg%s", local.instance_suffix)
  description = "Allow HTTPS from within the custom VPC to interface endpoints"
  vpc_id      = aws_vpc.custom.id
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront VPC origins"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.ecs_service.id
}

# Interface endpoints: ECR API, ECR Docker registry, CloudWatch Logs
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-ecr-api%s", local.instance_suffix) }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-ecr-dkr%s", local.instance_suffix) }
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-logs%s", local.instance_suffix) }
}

# Gateway endpoint: S3. Free, and required — ECR layers are stored in S3,
# so image pulls fail without this once there's no NAT Gateway route.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.custom.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = format("waypoint-vpce-s3%s", local.instance_suffix) }
}


#----------------------------------------------------------
# Security groups
#----------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = format("waypoint-alb-sg%s", local.instance_suffix)
  description = "Allow inbound HTTP from within the custom VPC" # From the CloudFront origin's prefix list
  vpc_id      = aws_vpc.custom.id
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ecs_service" {
  name        = format("waypoint-ecs-svc-sg%s", local.instance_suffix)
  description = "Allow inbound app traffic from the ALB only"
  vpc_id      = aws_vpc.custom.id
}

resource "aws_vpc_security_group_ingress_rule" "ecs_service_http" {
  security_group_id            = aws_security_group.ecs_service.id
  description                  = "App traffic from ALB"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "ecs_service_all" {
  security_group_id = aws_security_group.ecs_service.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

#----------------------------------------------------------
# ALB + target group + listener + CloudFront origin
#----------------------------------------------------------

resource "aws_lb" "app" {
  name               = format("waypoint-alb%s", local.instance_suffix)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id
}

resource "aws_lb_target_group" "app" {
  name        = format("waypoint-alb-tg%s", local.instance_suffix)
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.custom.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# CloudFront VPC origins require an attached internet gateway, but we don't actually
# want or need to route through it. TODO: this section seemed necessary on initial apply
# but its presence seemed to break other applies performed after that one. Requires closer analysis.
resource "aws_internet_gateway" "custom" {
  vpc_id = aws_vpc.custom.id

  tags = {
    Name = format("waypoint-igw%s", local.instance_suffix)
  }
}

resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = format("waypoint-alb-vpc-origin%s", local.instance_suffix)
    arn                    = aws_lb.app.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  timeouts {
    create = "30m"
  }
}

#----------------------------------------------------------
# Logging and alerts
#----------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = format("/ecs/waypoint%s", local.instance_suffix)
  retention_in_days = 14
}

resource "aws_sns_topic" "alerts" {
  name = format("waypoint-alerts%s", local.instance_suffix)
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "target_unhealthy" {
  alarm_name          = format("waypoint-target-unhealthy%s", local.instance_suffix)
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2 # ~2 min of unhealthy before alerting, avoids noise on brief deploys
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # no data usually means something's badly wrong too

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # also notify on recovery
}

#----------------------------------------------------------
# ECS task execution role
# (pulls from ECR, writes to CloudWatch Logs — nothing else)
#----------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = format("waypoint-ecs-task-execution%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#----------------------------------------------------------
# Cost guardrail
#----------------------------------------------------------

resource "aws_budgets_budget" "monthly_cap" {
  name         = format("waypoint-monthly-cap%s", local.instance_suffix)
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 30
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

#----------------------------------------------------------
# Frontend Hosting (S3 and CloudFront)
#----------------------------------------------------------

# S3 bucket for the SPA, private, OAC-only access:
resource "aws_s3_bucket" "frontend" {
  bucket = format("waypoint-frontend-%s-%s%s", local.account_id, local.region, local.instance_suffix)
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Origin Access Control, lets CloudFront read the bucket without it being public:
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = format("waypoint-frontend-oac%s", local.instance_suffix)
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Bucket policy — only this specific distribution's OAC may read:
data "aws_iam_policy_document" "frontend_bucket_policy" {
  statement {
    sid    = "AllowCloudFrontOAC"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.app.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket_policy.json
}

# CloudFront distribution — S3 origin only for now, no /report* behavior yet:
resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  default_root_object = "index.html"
  comment             = format("waypoint-frontend%s", local.instance_suffix)

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "alb-backend"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.alb.id
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-backend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    # No origin_request_policy_id: there's no authenticated route, so nothing
    # needs the Authorization header forwarded. Omitting it is the correct
    # default — CloudFront forwards only what cache_policy_id specifies.
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

#----------------------------------------------------------
# GitHub OIDC — apply this via LOCAL admin credentials
#----------------------------------------------------------

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}


# Shared: all roles need to read/write the state bucket, since `use_lockfile`
# writes a lock object even during `plan`.
data "aws_iam_policy_document" "state_backend_access" {
  statement {
    sid    = "StateBackendAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::waypoint-tfstate-${local.account_id}-${local.region}",
      "arn:aws:s3:::waypoint-tfstate-${local.account_id}-${local.region}/*",
    ]
  }
}

# --- Plan role: used on pull_request, read-only against AWS itself ---

data "aws_iam_policy_document" "github_oidc_plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = format("waypoint-gha-plan%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.github_oidc_plan_assume.json
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "github_plan_state_access" {
  name   = format("waypoint-gha-plan-state-access%s", local.instance_suffix)
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.state_backend_access.json
}

# --- Push role: used to push new build images. ---

data "aws_iam_policy_document" "github_oidc_push_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.github_oidc_subject_prefix}:ref:refs/heads/main"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/ci-build-push.yaml@refs/heads/main", var.github_repo)
      ]
    }
  }
}

resource "aws_iam_role" "github_push" {
  name               = format("waypoint-gha-push%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.github_oidc_push_assume.json
}

data "aws_iam_policy_document" "github_push_permissions" {
  statement {
    sid    = "ECRLogin"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushAccess"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListTagsForResource",
    ]
    resources = [aws_ecr_repository.container_registry.arn]
  }
}

resource "aws_iam_role_policy" "github_push_permissions" {
  name   = format("waypoint-gha-push-permissions%s", local.instance_suffix)
  role   = aws_iam_role.github_push.id
  policy = data.aws_iam_policy_document.github_push_permissions.json
}

resource "aws_iam_role_policy" "github_push_state_access" {
  name   = format("waypoint-gha-push-state-access%s", local.instance_suffix)
  role   = aws_iam_role.github_push.id
  policy = data.aws_iam_policy_document.state_backend_access.json
}

# --- Frontend deploy role: S3 sync + CloudFront invalidation only.
#     No Terraform, no state access — this role never touches infra/. ---

data "aws_iam_policy_document" "github_oidc_frontend_deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.github_oidc_subject_prefix}:ref:refs/heads/main"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/push-frontend.yaml@refs/heads/main", var.github_repo)
      ]
    }
  }
}

resource "aws_iam_role" "github_frontend_deploy" {
  name               = format("waypoint-gha-frontend-deploy%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.github_oidc_frontend_deploy_assume.json
}

data "aws_iam_policy_document" "github_frontend_deploy_permissions" {
  statement {
    sid    = "FrontendBucketSync"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::waypoint-frontend-${local.account_id}-${local.region}${local.instance_suffix}"
    ]
  }

  statement {
    sid    = "FrontendObjectSync"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutObjectTagging",
    ]
    resources = [
      "arn:aws:s3:::waypoint-frontend-${local.account_id}-${local.region}${local.instance_suffix}/*"
    ]
  }

  statement {
    sid    = "CloudFrontInvalidation"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = [aws_cloudfront_distribution.app.arn]
  }
}

resource "aws_iam_role_policy" "github_frontend_deploy_permissions" {
  name   = format("waypoint-gha-frontend-deploy-permissions%s", local.instance_suffix)
  role   = aws_iam_role.github_frontend_deploy.id
  policy = data.aws_iam_policy_document.github_frontend_deploy_permissions.json
}

# --- Apply role: used on updates to infrastructure, write access scoped to what
#     this stack actually manages. No IAM permissions on itself by design. ---

data "aws_iam_policy_document" "github_oidc_apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.github_oidc_subject_prefix}:ref:refs/heads/main"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/infra-apply.yaml@refs/heads/main", var.github_repo)
      ]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  name               = format("waypoint-gha-apply%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.github_oidc_apply_assume.json
}

data "aws_iam_policy_document" "github_apply_permissions" {
  statement {
    sid    = "ECRAccess"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListTagsForResource"
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ECSAccess"
    effect    = "Allow"
    actions   = ["ecs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ELBAccess"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }

  statement {
    sid       = "LogsAccess"
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "AlertingAccess"
    effect    = "Allow"
    actions   = ["sns:*", "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }

  statement {
    sid       = "BudgetsAccess"
    effect    = "Allow"
    actions   = ["budgets:*"]
    resources = ["*"]
  }

  statement {
    sid    = "NetworkingAccess"
    effect = "Allow"
    actions = [
      # VPC
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcAttribute",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",

      # Subnets
      "ec2:DescribeSubnets",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",

      # Route tables
      "ec2:DescribeRouteTables",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",

      # Internet gateway (currently commented out in main.tf, but iamlive
      # shows it was applied at some point — keep the perms since the
      # resource may come back)
      "ec2:DescribeInternetGateways",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",

      # VPC endpoints
      "ec2:DescribeVpcEndpoints",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyVpcEndpoint",

      # Prefix lists (CloudFront origin-facing list lookup)
      "ec2:DescribeManagedPrefixLists",
      "ec2:DescribePrefixLists",
      "ec2:GetManagedPrefixListEntries",

      # Misc reads terraform/iamlive both touch
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribeNetworkInterfaces",

      # Security groups (unchanged from before)
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",

      "ec2:CreateTags",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontAccess"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:ListOriginAccessControls",

      "cloudfront:CreateVpcOrigin",
      "cloudfront:GetVpcOrigin",
      "cloudfront:UpdateVpcOrigin",
      "cloudfront:DeleteVpcOrigin",

      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:ListDistributions",

      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
    ]
    # CloudFront's Create* actions don't support resource-level scoping —
    # the resource doesn't exist yet at call time. "*" is the realistic
    # floor here, not a shortcut; double-check against the CloudFront IAM
    # reference before treating this as final.
    resources = ["*"]
  }


  statement {
    sid    = "FrontendBucketInfraAccess"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketVersioning",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:GetBucketOwnershipControls",
      "s3:ListBucket",
      "s3:DeleteBucket",
    ]
    # Bucket-level infra CRUD only — this is what `terraform apply` itself
    # needs to stand the bucket up. Object PUTs (the actual file sync) are
    # the frontend deploy role's job, not the apply role's — see below.
    resources = [
      "arn:aws:s3:::waypoint-frontend-${local.account_id}-${local.region}${local.instance_suffix}"
    ]
  }


  statement {
    sid    = "ResourceGroupAccess"
    effect = "Allow"
    actions = [
      "resource-groups:*"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "IAMReadAccess"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetOpenIDConnectProvider"
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassExecutionRoleOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_task_execution.arn]
  }
}

resource "aws_iam_role_policy" "github_apply_permissions" {
  name   = format("waypoint-gha-apply-permissions%s", local.instance_suffix)
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.github_apply_permissions.json
}

resource "aws_iam_role_policy" "github_apply_state_access" {
  name   = format("waypoint-gha-apply-state-access%s", local.instance_suffix)
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.state_backend_access.json
}


#----------------------------------------------------------
# ECS task definition + service
# Applied at the very end for the sake of the initial setup process, since
# this resource won't finish creating until the manual initial image upload. 
#----------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = format("waypoint%s", local.instance_suffix)
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = format("waypoint%s", local.instance_suffix)
      image     = format("%s:%s", aws_ecr_repository.container_registry.repository_url, var.image_tag)
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "PORT"
          value = tostring(var.container_port)
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = format("waypoint%s", local.instance_suffix)
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = format("waypoint-service%s", local.instance_suffix)
  cluster         = aws_ecs_cluster.container_cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = format("waypoint%s", local.instance_suffix)
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]
}
