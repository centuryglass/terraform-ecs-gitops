# Architecture
NOTE: This document is to remain 100% human-authored, as writing it serves as a mechanism to ensure the project is fully understood at the human level. AI coding assistants are allowed to flag mistakes and omissions, but must do so in a separate file.

## Build pipeline

1. Changes pushed to `main` that touch the dockerfile, stack file, or anything under src/, app/, or webapp/ trigger the "aws-build-push" GitHub Action defined in `.github/workflows/aws-build-push.yaml`.
2. GitHub allocates a VM running 'ubuntu-latest' to run the build job, which then does the following:
    1a. IMAGE_TAG, BRANCH_NAME, and PREV_TAG environment variables are set for future use.
    1b. The job logs into Amazon ECR using OIDC and the waypoint-gha-push role. This step is done before the build to ensure we will actually be able to upload the build image.
    1c. To ensure the build has enough space to complete, several large toolsets that we don't need that are present in the VM are deleted. 
    1d. Docker buildx is used to compile the project and build a docker image. Dependencies and sources are built in separate stages, so that dependencies don't need to be rebuilt every time. Docker build files are cached in the GitHub Actions cache.
    1e. After the build succeeds, the image is tagged with the short commit hash and pushed to ECR.
    1f. A PR is opened that sets or updates the build image defined in `infra/prod-aws/image.auto.tfvars`. This PR links to the diff between the previous and current deployed image.
3. The automatic build PR's changes under `infra` would trigger the "aws-tf-plan" action defined in `.github/workflows/aws-tf-plan.yaml`, but GitHub-created PRs won't ever directly start other actions. Instead, a prompt will appear on the PR asking the user to start the job. When triggered, this runs `terraform plan` and posts the output to the PR. In this case, this mostly serves to confirm the infrastructure is still in a valid state in sync with current definitions.
4. Once the build PR is merged, the "aws-tf-apply" action defined in `.github/workflows/aws-tf-apply.yaml` is triggered, updating the docker image tag connected to the ECS.
5. ECS starts up the new image container, waits for it to pass health checks, begins routing traffic to the new container, and shuts down the old one.

If quick rollback is necessary, the automatic build PR can be reverted to switch back to the previous image. 
---

## Component choice and justifications

### High-level overview

| Component              | Implementation                    |
|------------------------|-----------------------------------|
| Cloud host             | AWS                               |
| Authentication/Security| GitHub OIDC, Scoped IAM roles     |
| Frontend Hosting       | S3                                |
| Infrastructure-as-code | Terraform (S3-backed)             |
| Docker image build     | GitHub Actions                    |
| Build image repo       | Amazon Elastic Container Registry |
| Network                | Custom VPC, CloudFront            |
| Logging and Alerts     | Amazon CloudWatch and SNS         |
| Container hosting      | Amazon Elastic Container Service  |
| Load balancing         | Amazon Application Load Balancer  |

### Cloud host: AWS

To simplify the initial design, I chose an approach that centralizes all components on a single cloud provider. AWS has a well-deserved reputation as the industry standard, and is an obvious pick for a simple initial service like this. At this scale there are many providers that would be acceptable for this job, and even self-hosting is entirely viable, but AWS is a good default if you have plans to scale up and don't know which direction you're taking yet. Given more in-depth business plans, I'd take the time to carefully consider GCP, Azure, and possibly even dev-focused systems like DigitalOcean, or basic PaaS systems like Render.

### Authentication/Security: GitHub OIDC, Scoped IAM roles
Using scoped roles to handle CI/CD jobs is standard practice, and ensures that build scripts can't be easily reworked to access AWS in inappropriate ways. GitHub OIDC ties authentication to the IAM role, scoping it specifically to changes from this repository. This avoids the need to store AWS secrets in GitHub, and also allows us to limit each role to specific branches and build scripts.

### Frontend hosting: S3
Because the frontend web components are completely static, they can be directly hosted within S3. Moving these files to an S3 bucket instead of serving them directly from the application server allows us to make frontend changes without the need to completely rebuild the project and push a new Docker image.

### Infrastructure-as-code: Terraform (S3-backed)

Terraform is an ideal choice for code-defined resource creation and management because of its flexibility and broad support. At this scale, Terraform and CloudFormation are really the only appropriate choices, although Pulumi and Crossplane are worth remembering as possibilities for future projects. Both Terraform and CFN are comparable in terms of ease of use and effectiveness, but the difficulty of using CFN if you want to move outside of the Amazon ecosystem is a hassle that's worth avoiding. Terraform's lack of automatic rollback on failure is a definite downside, but I consider it a worthwhile tradeoff in this case. 


### Docker image build: GitHub Actions and Docker Buildx

The free compute provided by GitHub Actions is more than good enough for this particular project. Docker Buildx can use the GitHub Actions cache to store build files, so the average build can skip recompiling dependencies, and completes in roughly ten minutes. Once security scans and testing are added to the build pipeline, it'll likely be wise to move compilation to AWS CodeBuild to decrease runtimes. Simply using GitHub Large Runners might also be a viable option though, depending on cost concerns and whether CodeBuild's deeper AWS integration is desirable.

### Build image repo: Amazon Elastic Container Registry

At this scale, container hosting costs are trivial, and ECR is worth choosing simply because it's already on AWS. Outside of AWS, the Docker Hub is also a solid default choice. Many alternatives exist, but it seems like they're largely interchangable unless you have more advanced hosting needs.

### Container hosting: Amazon Elastic Container Service and Fargate

ECS and Fargate are ideal for handling reasonably priced, minimal container hosting on AWS while still providing significant flexibility. EKS is really the only alternative worth considering within the AWS ecosystem. That requires migrating to Kubernetes though, which is outside the scope of this project. If cost is a concern, EC2 might also be worth considering, but maintaining a fixed node adds extra overhead in terms of maintenance that is worth avoiding.

### Network: Custom VPC, CloudFront VPC origin
Using a custom VPC is standard practice to ensure network communications between different resources are fully managed. A CloudFront distribution with separate origins gatekeeping access to the server and frontend provides several distinct advantages:
1. TLS encryption is automatically handled for all network traffic.
2. Regional caching has the potential to decrease server load if we add API functionality that can benefit from it.
3. Access to the backend server can be strictly restricted to only traffic from the frontend site, and only to specific selected endpoints.

This has the disadvantage of slightly complicating logging, increasing infrastructure complexity, and increasing the cost of backend hosting. The benefits provided by this approach are mostly insignificant for applications that are intended to remain small-scale, so this approach should be saved for projects that will need to be scaled up later.

### Logging and Alerts: Amazon CloudWatch, SNS Alerts
Given a single application with minimal logging, CloudWatch and email alerts are sufficient for handling these steps. Container console output is logged to a Waypoint log group, and email alerts are sent out if the server is offline for more than two minutes. Budget alerts are also configured to track spend and email if costs go outside of expected bounds.

For a larger organization, a more comprehensive logging solution aggregating multiple sources is well worth the extra configuration and cost. Elastic Stack is my go-to choice in this situation. To handle real emergencies, we would also definitely want something that can send more urgent alerts and coordinate responses. PagerDuty is top-notch, but cheaper alternatives are definitely worth investigating.

### Load balancing: Amazon Application Load Balancer
Load balancing at this scale really only requires routing traffic to the single container, and gracefully handling the transition when deploying updates. ALB handles that simply, but is versatile enough to support more complicated configurations in the future. Alternatives are really only relevant in niche cases that don't apply here.

---

