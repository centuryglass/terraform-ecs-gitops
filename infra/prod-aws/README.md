# Environment Setup and Maintenance

## File overview:
- `prod-aws/bootstrap/main.tf`: Initializes the Terraform S3 bucket and generates the Terraform backend file.
- `prod-aws/backend.tf`: Defines Terraform's S3 backend where the environment state is tracked.
- `prod-aws/main.tf`: Defines the Terraform AWS and TLS providers and the application's resource group.
- `prod-aws/edge.tf`: Defines frontend hosting, the CloudFront distribution, and the application load balancer.
- `prod-aws/network.tf`: Defines the VPC, routing, and network security rules.
- `prod-aws/ecs.tf`: Defines the backend server container repository and the ECS task definition, service, and task execution role.
- `prod-aws/observability.tf`: Defines logging, alerts, and budget tracking.
- `prod-aws/github-oidc.tf`: Defines OIDC authentication and scoped IAM roles used by GitHub Actions.
- `prod-aws/variables.tf`: Variables used across all files directly under `prod-aws/` (except backend.tf).
- `prod-aws/outputs.tf`: Final resource identifiers read from AWS after resources are created or updated.
- `prod-aws/image.auto.tfvars`: Auto-generated file defining the current server image tag.
- `prod-aws/backend_enabled.auto.tfvars`: On/off switch for the pay-per-hour backend tier (see "Cost model" below).

## Initial setup
Initial environment setup needs to be executed locally via command line.

1. Make sure the `aws` and `terraform` command line tools are installed on your local system.
2. Use `aws login` to log in to an AWS account that has authorization to create all needed resources. If that isn't your default AWS account, make sure to `export AWS_PROFILE=${your_profile_name}` to ensure terraform uses the correct credentials.
3. Use terraform to set up its own S3 state management:
    ```
    cd terraform-ecs-gitops/infra/prod-aws/bootstrap
    terraform init
    terraform apply
    ```
    Validate that the changes look correct and enter "yes" to confirm. In addition to creating the S3 bucket, terraform will also update `infra/prod-aws/backend.tf`. Make sure to commit any changes made to backend.tf to the main repository branch to ensure CI/CD functions correctly.
4. Run terraform again in the `infra/prod-aws` directory to initialize resources:
    ```
    cd terraform-ecs-gitops/infra/prod-aws
    terraform init
    terraform apply
    ```
    Validate changes and enter "yes" to confirm.
    After it is complete, a set of outputs will be printed. Make sure to also note the cloudfront_domain_name output, that will be the address used to access the deployed application.
5. After the resources have been created, ensure the 'prod' GitHub environment exists, and run the environment update script to set environment variables
   ```
   cd terraform-ecs-gitops
   ./scripts/set-ci-env-vars.sh prod-aws
   ```
6. Once all changes have been applied and those variables have been updated, manually trigger the "Deploy Frontend" workflow under the GitHub Actions tab to push initial frontend code to S3.
7. Do the same with the "Build and Push" workflow, which will build the backend server image, push it to ECR, and create an automatic PR to update the active image.
8. Approve and merge the generated "Deploy ${commit_id}" PR, and the initial image will be applied, and should be up and running within minutes.

## Ongoing Infrastructure Changes
After the initial setup, PRs modifying `infra/prod-aws` that target `main` can be used to automatically make infrastructure changes. When an infrastructure PR is opened, the GitHub Actions `aws-tf-plan` workflow will run `terraform plan` against the proposed changes. If the changes are valid, it will post the plan output to the PR to show exactly how the changes will affect the environment.

Once the PR is merged into `main`, changes will be automatically applied by the `aws-tf-apply` workflow.

## Cost model: the on-demand backend
This stack is built to idle at roughly **$0/month** and only cost money while a live demo is actually needed. The pay-per-hour resources — the ALB, the ECS/Fargate service, the three interface VPC endpoints, and the CloudFront VPC origin + `/api/*` behavior (~$69/month combined) — are gated behind the `backend_enabled` variable, whose committed value lives in `backend_enabled.auto.tfvars`. Everything else (the VPC, S3 + CloudFront static hosting, ECR, IAM roles, log group, budgets) is free or costs pennies and stays applied.

Toggle the backend the same GitOps way as any other change:
- **To bring it online:** open a PR setting `backend_enabled = true` in `backend_enabled.auto.tfvars`. `aws-tf-plan` posts the list of resources to be created; merging runs `aws-tf-apply` and the backend is live within a few minutes (CloudFront propagation is the slow part).
- **To take it back down:** set it to `false` the same way. The backend tier is destroyed and the stack returns to its dormant state.

While the backend is off, the static site still loads and the app surfaces its built-in "backend unreachable" state for `/api/*` calls. The `waypoint-daily-tripwire` and `waypoint-monthly-cap` budgets in `observability.tf` are sized to alert quickly if the backend is ever left running unintentionally.

(`moved.tf` is a one-time state-migration helper for the introduction of this toggle and can be deleted once it has been applied against all live state.)

## Permission management
The apply IAM role should only be given permission to create and modify resource types that are actually used. If new AWS resource types need to be added, permissions to use those resources will need to be updated in `infra/prod-aws/github-oidc.tf` before CI/CD can create or manage them. Do not give the role IAM permissions it could use to self-modify, create new roles, or assume arbitrary roles. Because the role cannot self-modify, role changes must be applied locally by following the "Initial setup" process above.
