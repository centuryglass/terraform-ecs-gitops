# alb_dns_name in outputs.tf: update description to note it's now internal-only
output "alb_dns_name" {
  description = "Internal ALB DNS name - not the deployed URL. Only resolves inside the VPC. Kept for debugging."
  value       = "http://${aws_lb.app.dns_name}"
}

output "ecr_repository_url" {
  description = "Push images here from ci-build-push.yml."
  value       = aws_ecr_repository.container_registry.repository_url
}

output "plan_role_arn_github" {
  description = "Set as a GitHub repo action variable to use in infra-plan.yml."
  value       = aws_iam_role.github_plan.arn
}

output "push_role_arn_github" {
  description = "Set as a GitHub repo action variable to use in ci-build-push.yml."
  value       = aws_iam_role.github_push.arn
}

output "apply_role_arn_github" {
  description = "Set as a GitHub repo action variable infra-apply.yml."
  value       = aws_iam_role.github_apply.arn
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "cloudfront_domain_name" {
  description = "New deployed URL once the ALB origin/behavior is added and DNS propagates - S3-only for now, no backend routing yet."
  value       = aws_cloudfront_distribution.app.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.app.id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.id
}


output "frontend_deploy_role_arn_github" {
  description = "Set as a GitHub repo action variable to use in ci-build-frontend.yaml."
  value       = aws_iam_role.github_frontend_deploy.arn
}
