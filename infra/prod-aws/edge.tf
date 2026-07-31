#----------------------------------------------------------
# ALB + target group + listener + CloudFront origin
#----------------------------------------------------------

resource "aws_lb" "app" {
  count              = local.vpc_origin_alive ? 1 : 0
  name               = format("waypoint-alb%s", local.instance_suffix)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id
}

resource "aws_lb_target_group" "app" {
  count       = var.backend_enabled ? 1 : 0
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
  count             = var.backend_enabled ? 1 : 0
  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# CloudFront VPC origins require an attached internet gateway, but we don't actually
# want or need to route through it. TODO: this section seemed necessary on initial apply
# but its presence seemed to break other applies performed after that one. Requires closer analysis.
resource "aws_internet_gateway" "custom" {
  count  = var.backend_enabled ? 1 : 0
  vpc_id = aws_vpc.custom.id

  tags = {
    Name = format("waypoint-igw%s", local.instance_suffix)
  }
}

# Teardown ordering caveat: this origin can't be deleted while the distribution
# below still references it (AWS returns 409 CannotDeleteEntityWhileInUse), and
# Terraform does NOT order the distribution's in-place update (dropping the
# origin) ahead of this destroy in a single apply — the delete races the update,
# fails, and the run aborts before the update commits, so every retry re-wedges.
# It also can't be fixed with a depends_on (the distribution references this
# origin's id, so the reverse dependency would be a cycle).
#
# The fix is a two-apply teardown, driven by scripts/aws-safe-apply.sh (what CI's
# aws-tf-apply runs): apply #1 sets retain_backend_origin=true, which keeps this
# origin (and the ALB it points at, via local.vpc_origin_alive) alive while the
# distribution — gated on backend_enabled alone — drops its reference; apply #2,
# with retain_backend_origin back to false, deletes this now-orphaned origin
# cleanly. A plain `terraform apply` on a backend_enabled=false diff will wedge.
resource "aws_cloudfront_vpc_origin" "alb" {
  count = local.vpc_origin_alive ? 1 : 0
  vpc_origin_endpoint_config {
    name                   = format("waypoint-alb-vpc-origin%s", local.instance_suffix)
    arn                    = aws_lb.app[0].arn
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

# Force browsers to revalidate the static assets on every load. Without an
# explicit Cache-Control, browsers apply *heuristic* caching (guessing a
# freshness lifetime from Last-Modified) and serve a stale page even after a
# CloudFront invalidation, because they never revalidate against the edge.
#
# `no-cache` = "store, but revalidate before use" — the browser sends a
# conditional request and CloudFront answers with a cheap 304 when unchanged.
# The ideal pattern (long-lived `immutable` caching for content-hashed asset
# filenames) isn't available here: the frontend has no build step (APP-SPEC §2),
# so nothing fingerprints app.js/index.css, and any of them can change in place
# on a deploy. Uniform revalidation is the correct choice under that constraint.
# This pairs with the deploy's CloudFront invalidation: this makes the browser
# ask; the invalidation makes the edge answer with fresh content.
resource "aws_cloudfront_response_headers_policy" "frontend_revalidate" {
  name = format("waypoint-frontend-revalidate%s", local.instance_suffix)

  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "no-cache"
      override = true
    }
  }
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

  # Backend origin only exists while the backend tier is up (var.backend_enabled).
  # When it's off, the distribution keeps serving the S3 static site and /api/*
  # falls through to the S3 default behavior (404 → the app's "backend
  # unreachable" state).
  dynamic "origin" {
    for_each = var.backend_enabled ? [1] : []
    content {
      domain_name = aws_lb.app[0].dns_name
      origin_id   = "alb-backend"

      vpc_origin_config {
        vpc_origin_id = aws_cloudfront_vpc_origin.alb[0].id
      }
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-frontend"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.frontend_revalidate.id
  }

  # /api/* behavior is paired with the backend origin above — present only while
  # the backend tier is up.
  dynamic "ordered_cache_behavior" {
    for_each = var.backend_enabled ? [1] : []
    content {
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
