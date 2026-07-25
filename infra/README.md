# Environment Setup and Maintenance

## Initial setup
Initial environment setup needs to be executed locally via command line.

1. Make sure the `aws` and `terraform` command line tools are installed on your local system.
2. Use `aws login` to log in to an AWS account that has authorization to create all needed resources. If that isn't your default AWS account, make sure to `export AWS_PROFILE=${your_profile_name}` to ensure terraform uses the correct credentials.
3. Use terraform to set up its own S3 state management:
    ```
    cd terraform-ecs-gitops/infra/bootstrap
    terraform init
    terraform apply
    ```
    Validate that the changes look correct and enter "yes" to confirm. In addition to creating the S3 bucket, terraform will also update `infra/live/backend.tf`. Make sure to commit any changes made to backend.tf to the main repository branch to ensure CI/CD functions correctly.
4. Run terraform again in the `infra/live` directory to initialize resources:
    ```
    cd terraform-ecs-gitops/infra/live
    terraform init
    terraform apply
    ```
    Validate changes and enter "yes" to confirm.
5. For the service to initialize properly you'll need to push an initial build image to ECR. Once terraform prints that the ECR resource has been created, navigate to it in the AWS web UI, click the "View push commands" button, and follow instructions to push a local build of the Docker image, tagged to match whatever is currently in `infra/live/image.auto.tfvars` (or update that file to match the tag you push). TODO: eliminate this step!
6. After the resources have been created, terraform will print output values. Add all of the following to this GitHub repository's Actions variables (Settings → Secrets and variables → Actions → Variables) — the workflows read these by name, and a missing one just fails silently as an empty string rather than an obvious error:
   - `plan_role_arn_github` → `PLAN_ROLE_ARN_GITHUB`
   - `push_role_arn_github` → `PUSH_ROLE_ARN_GITHUB`
   - `apply_role_arn_github` → `APPLY_ROLE_ARN_GITHUB`
   - `frontend_deploy_role_arn_github` → `FRONTEND_DEPLOY_ROLE_ARN_GITHUB`
   - `frontend_bucket_name` → `FRONTEND_BUCKET_NAME`
   - `cloudfront_distribution_id` → `CLOUDFRONT_DISTRIBUTION_ID`

## Ongoing Infrastructure Changes
After the initial setup, PRs modifying `infra/live` that target `main` can be used to automatically make infrastructure changes. When an infrastructure PR is opened, the GitHub Actions infra-plan task will run `terraform plan` against the proposed changes. If the changes are valid, it will post the plan output to the PR to show exactly how the changes will affect the environment.

Once the PR is merged into `main`, changes will be automatically applied by the infra-apply task.

## Permission management
The infra-apply IAM role should only be given permission to create and modify resource types that are actually used. If new AWS resource types need to be added, permissions to use those resources will need to be updated in `infra/live/main.tf` under "github_apply_permissions" before CI/CD can create or manage them. Do not give the role IAM permissions it could use to self-modify, create new roles, or assume arbitrary roles. Because the role cannot self-modify, role changes must be applied locally by following the "Initial setup" process above.
