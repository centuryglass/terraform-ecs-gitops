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
    # Because the plan job references `environment: prod`, GitHub rewrites the
    # sub claim to the environment form (`...:environment:prod`) — it can no
    # longer carry `:pull_request`. So we pin the repo+environment via sub, then
    # restore the PR scoping with the dedicated claims: event_name = pull_request
    # and base_ref = main. This keeps the read-only plan role usable only by
    # PRs into main, and not by the deploy jobs that share the same sub.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject_prefix}:environment:prod"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:event_name"
      values   = ["pull_request"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:base_ref"
      values   = ["main"]
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

    # All four AWS reusables reference `environment: prod`, so the sub claim is
    # the environment form for the deploy roles too (it no longer carries the
    # branch). The branch pin comes from job_workflow_ref below, which ends in
    # `@refs/heads/main` and only ever resolves that way on a push to main.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.github_oidc_subject_prefix}:environment:prod"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/reusable-aws-build-push.yml@refs/heads/main", var.github_repo)
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
        "${var.github_oidc_subject_prefix}:environment:prod"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/reusable-aws-frontend.yml@refs/heads/main", var.github_repo)
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
        "${var.github_oidc_subject_prefix}:environment:prod"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        format("%s/.github/workflows/reusable-aws-tf-apply.yml@refs/heads/main", var.github_repo)
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
    sid    = "AlertingAccess"
    effect = "Allow"
    actions = [
      "sns:*", "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:ListTagsForResource",
      "cloudwatch:DescribeAlarms"
    ]
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
      "s3:GetBucketTagging",
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
