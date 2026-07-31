# Waypoint: Terraform DevOps Experimentation
This repository is an example implementation of a web application hosting setup and CI/CD pipeline managed by Terraform and GitHub Actions. It also serves as a space for personal experiments with DevOps pipelines and in integrating Claude Code into my existing work habits.

## The Application:
[Waypoint](https://waypoint-live-0857.web.app) is an intentionally minimal web application created for demonstration purposes.  It consists of a stateless REST server and a static frontend, mostly designed to demonstrate that the surrounding infrastructure works correctly. The server is written in go, chosen because the language is particularly capable of hosting a webserver in a single tiny binary with no dependencies. As a side project, it also exists as an area to experiment with AI-driven creative work within tight constraints.

The link above points at the always-on GCP live demo; the AWS stack below hosts the same application but is spun up on demand rather than run continuously (see "The Infrastructure").

## The Infrastructure
The same application is deployed to two clouds that play deliberately different roles, both defined in this repo with Terraform:

- **AWS: the reference stack.** The fuller, enterprise-style build: S3 for frontend hosting, ECS/Fargate for the server container, and CloudFront, a private ALB, and a custom VPC for network management. To keep a portfolio piece from costing money while idle, its pay-per-hour tier is gated behind a `backend_enabled` toggle and normally left dormant (~$0/month), then applied in ~30 minutes when a live AWS demo is wanted. See the [AWS infra README](./infra/prod-aws/README.md) for setup, file structure, and the cost toggle, and [ARCHITECTURE.md: Component choice and justifications](./docs/ARCHITECTURE.md#-component-choice-and-justifications) for the rationale.
- **GCP: the always-on live demo.** A lean, scale-to-zero stack sized to run continuously for effectively free: [Firebase Hosting](https://waypoint-live-0857.web.app) serves the static frontend and rewrites `/api/**` to a Cloud Run service (`us-central1`) that scales to zero when idle, with container images in Artifact Registry. Defined under [`infra/dev-gcp/`](./infra/dev-gcp/). This is what the application link above serves.

Running the identical app across both also doubles as a multi-provider Terraform exercise.

## The CI/CD Pipeline
Building, deployment, and infrastructure updates are all applied automatically through GitHub Actions in response to changes to the relevant project files. Both clouds follow the same GitOps pattern, image builds and `terraform plan`/`apply` triggered by branch pushes and PRs, authenticating via GitHub OIDC (AWS IAM roles / GCP Workload Identity Federation) with no long-lived cloud credentials. AWS deploys from the `main` branch and GCP from `dev`. See [ARCHITECTURE.md: Build pipeline](./docs/ARCHITECTURE.md#-build-pipeline) for the full pipeline structure.

