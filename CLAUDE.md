# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A reference implementation of a container deployment pipeline: Terraform-managed
AWS infrastructure + GitHub Actions CI/CD + a GitOps promotion flow where image-tag
bumps arrive as reviewable pull requests carrying a `terraform plan` in the PR
comments. **The infrastructure is the deliverable; the application is a fixture**
whose only jobs are to exercise every routing path the infrastructure defines and
to stay small. See `docs/APP-SPEC.md` for the full rationale.

This started as a take-home coding assignment; the goal now is a public
GitHub portfolio piece, with all third-party branding replaced. See
`docs/PRIORITIES.md` for the author's actual motivations, in priority order:
(1) hands-on DevOps/IaC experimentation and a template for future projects,
(2) a deliberate, cost- and skill-conscious experiment in agentic coding — so
default to focused, direct work over heavy multi-agent orchestration unless
asked, and (3) using the frontend fixture's visual (§6 of `APP-SPEC.md`) as a
genuine LLM-driven-art exercise, not filler. Priority 3 means that part of the
spec should be read as a real creative brief.

## Current state — read this before assuming anything is missing

There is currently **no application code in this repo** — no `Dockerfile`, no
`src/`, `app/`, or `webapp/` directory, no `stack.yaml`. Only two things exist:

- `infra/` — the Terraform stack (fully built out, all resources renamed from
  the original take-home's naming to `waypoint` — see "Renaming" below).
- `.github/workflows/` — CI/CD workflows already wired up and pointed at paths
  (`Dockerfile`, `src/**`, `app/**`, `webapp/**`) that don't exist yet.

`docs/APP-SPEC.md` is the authoritative spec for building the replacement app
(the prior app was Haskell-based and has been fully removed). If asked to
implement the app, that document — not this file — is the source of truth for
routes, the build-metadata plumbing, and the frontend constraints. Section 2 of
that spec ("hard contract") lists things that must not change without a
corresponding Terraform change; treat that table as load-bearing.

## Commands

There is no application build/lint/test tooling yet (see above). The only
commands that currently apply are Terraform, run from `infra/live` (the main
stack) or `infra/bootstrap` (one-time state-bucket setup):

```bash
cd infra/live
terraform init
terraform fmt -recursive -diff
terraform validate
terraform plan
terraform apply
```

CI runs exactly this sequence (`infra-plan.yaml` on PRs touching `infra/**`,
`infra-apply.yaml` on merge to `main`) — reproduce plan output locally the same
way before pushing infra changes. `infra/bootstrap` is applied manually, once,
per the "Initial setup" steps in `infra/README.md`; it is not part of CI.

## Architecture

### Traffic path

```
                    CloudFront
                   /          \
       default    /            \  /api/*
                 v              v
        S3 (static, OAC)    ALB (private, VPC origin)
                                     |
                                     v
                            ECS Fargate task (private subnet, no NAT)
```

Same-origin is achieved by CloudFront routing, not CORS — the frontend must
call the backend with relative URLs. The Fargate task has no public IP and no
NAT gateway; it reaches ECR and CloudWatch Logs exclusively through VPC
interface endpoints (`ecr.api`, `ecr.dkr`, `logs`) plus an S3 gateway endpoint
for ECR layer storage. All of this is defined in `infra/live/main.tf`, which is
a single flat file (no modules) organized into commented sections: resource
group → ECR/ECS cluster → VPC/endpoints → security groups → ALB/CloudFront →
logging/alerts → IAM (task execution role, then the four GitHub OIDC roles) →
ECS task definition/service (deliberately last, since it can't finish creating
until an image exists in ECR).

### GitOps pipeline (see `docs/ARCHITECTURE.md` for the full human-authored writeup)

1. A push to `main` touching the Dockerfile/app sources triggers
   `ci-build-push.yaml`: builds and pushes an image to ECR tagged with the
   short commit SHA, then opens a PR (via a PAT, not `GITHUB_TOKEN` — see
   comment in that workflow) that bumps `image_tag` in
   `infra/live/image.auto.tfvars`.
2. That PR's diff under `infra/` triggers `infra-plan.yaml`, which posts
   `terraform plan` output as a PR comment.
3. Merging the PR triggers `infra-apply.yaml`, which runs `terraform apply`
   and rolls the ECS service to the new image.
4. Pushes touching `webapp/**` trigger `push-frontend.yaml` independently —
   `aws s3 sync` plus a CloudFront invalidation, no Docker/Terraform involved.

Four distinct IAM roles back these workflows via GitHub OIDC, each scoped to a
specific `job_workflow_ref` so a workflow can only assume the role built for
it: `github_plan` (read-only), `github_push` (ECR push only), `github_apply`
(infra CRUD, explicitly denied any IAM self-modification — see the
`PassExecutionRoleOnly` statement and the comment above it in `main.tf`), and
`github_frontend_deploy` (S3 sync + CloudFront invalidation only, no state
access, never touches `infra/`).

### Config file split

- `infra/live/terraform.tfvars` — personal/local config (`github_repo`,
  `alert_email`), gitignored, not written by CI.
- `infra/live/image.auto.tfvars` — the one line CI rewrites every deploy
  (`image_tag`). Kept separate specifically so CI's writes and personal config
  never touch the same file.
- `infra/live/backend.tf` — generated by `infra/bootstrap`'s `local_file`
  resource, not hand-edited. Re-run bootstrap if the state bucket changes.

### Renaming — done in code, not yet applied

All resources were renamed from the original take-home's naming to
`waypoint*` (per the `docs/APP-SPEC.md` §8 checklist) directly in
`infra/live/main.tf`, `infra/bootstrap/main.tf`, `backend.tf`, `variables.tf`,
`terraform.tfvars`, `infra/README.md`, and `ci-build-push.yaml`.
`github_repo` now points at `centuryglass/terraform-ecs-gitops` (the real
repo, replacing the original hiring company's org/repo).

This has **not been applied to AWS yet**. The old deployment (under the prior
naming) is being torn down separately, outside this repo — not this
directory's concern. `infra/bootstrap/terraform.tfstate` and
`infra/live/errored.tfstate` are stale local artifacts from before the
rename; they reference the old naming and a real AWS account ID and must
never be committed (see `.gitignore`). Do not hand-edit `.tfstate` files to
"fix" the naming — that's not how Terraform state works and will corrupt it.
A fresh `terraform apply` (once `infra/bootstrap` is re-run to create a new
state bucket) will create clean `waypoint-*` resources with no migration
needed.

## Documentation map

- `docs/ARCHITECTURE.md` — **100% human-authored by design** (stated at the
  top of the file as a comprehension check). Do not edit this file's content
  directly; if you spot a mistake or omission, flag it separately instead of
  fixing it in place.
- `docs/APP-SPEC.md` — the spec for the not-yet-built replacement app (backend
  routes, frontend constraints, required Terraform changes, pre-publish
  checklist). Treat as authoritative when implementing the app.
- `infra/README.md` — operational setup/maintenance guide (bootstrap steps,
  ongoing PR flow, IAM permission-management rules for the apply role).
- `docs/PRIORITIES.md` — the author's goals for this project, in priority
  order. Read before making judgment calls about scope or how much creative
  latitude to take.
