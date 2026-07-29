# Waypoint: Terraform DevOps Experimentation
This repository is an example implementation of a web application hosting setup and CI/CD pipeline managed by Terraform and GitHub Actions. It also serves as a space for personal experiments with DevOps pipelines and in integrating Claude Code into my existing work habits.

## The Application:
[Waypoint](https://do4ze9kdfi6sz.cloudfront.net) is an intentionally minimal web application created for demonstration purposes.  It consists of a minimal stateless REST server and a static frontend, mostly designed to demonstrate that the surrounding infrastructure works correctly. The server is written in go, chosen because the language is particularly capable of hosting a webserver in a single tiny binary with no dependencies. As a side project, it also exists as an area to experiment with AI-driven creative work within extremely tight constraints.

## The Infrastructure
All infrastructure is hosted in AWS, and defined within this repo using Terraform. See the [infra README](./infra/prod-aws/README.md) for more information about infrastructure-as-code setup and file structure. The primary cloud components are S3 for frontend hosting, ECS server container hosting, and CloudFront, ALB, and a custom VPC for network management. See [ARCHITECTURE.md: Component choice and justifications](./docs/ARCHITECTURE.md#-component-choice-and-justifications) for further details.

## The CI/CD Pipeline
Building, deployment, and infrastructure updates are all applied automatically through GitHub Actions in response to changes to the relevant project files within the main branch or PRs targeting the main branch. See [ARCHITECTURE.md: Build pipeline](./docs/ARCHITECTURE.md#-build-pipeline) for the full pipeline structure.

