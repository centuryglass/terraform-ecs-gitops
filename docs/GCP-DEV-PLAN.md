# GCP "Live Demo" Environment — Implementation Plan

**Status:** planned, not yet built (as of 2026-07-28).

## Why this exists

The AWS stack (`infra/prod-aws/`) is the enterprise-grade *reference* deployment,
but it costs ~$69/mo to run always-on (dominated by ~$44 for three interface
VPC endpoints + ~$16 ALB + ~$9 Fargate) — indefensible for a portfolio piece.

So the project splits into two environments:

- **Live demo (this plan, GCP):** Firebase Hosting (static) + Cloud Run
  (backend), same-origin `/api/**`, scale-to-zero. **Effectively $0/mo** for
  portfolio traffic. This is the environment linked from the README that a
  visitor actually clicks.
- **Reference stack (existing, AWS):** the full ECS-Fargate-behind-ALB-behind-
  CloudFront-with-private-VPC-endpoints design. Kept as reproducible IaC that
  can be `terraform apply`-ed in ~30 min to demonstrate, then torn down.

This split is also the Terraform multi-provider story: the *same container
image* and the *same GitOps workflow* (build → PR carrying a plan → apply)
run on both clouds; only the resource definitions differ.

> **Naming:** "live demo" (GCP) vs "reference stack" (AWS) is preferred over
> dev/prod, since an always-on public "dev" fronting a dormant "prod" inverts
> the usual convention and reads oddly in a README. (Open decision.)

## Verified free-tier facts (2026-07-28)

- **Cloud Run** (per billing account/mo, US regions incl. `us-central1`):
  2,000,000 requests, 180,000 vCPU-seconds, 360,000 GiB-seconds, 1 GiB North
  America egress. Requires a **linked billing account (Blaze)** even at $0 usage.
- **Firebase Hosting** (Spark, free): 10 GB storage, 360 MB/day transfer, free
  managed SSL + custom domain.
- **Firebase → Cloud Run rewrite:** region defaults to `us-central1` (aligns
  with Cloud Run free tier). Cloud Run must grant `allUsers` →
  `roles/run.invoker` for Hosting to reach it — acceptable here, the service
  only serves harmless build/runtime JSON.
- **Artifact Registry:** the one genuinely non-zero line (~pennies) — mitigate
  with an image cleanup policy.

## Cost summary

| Component          | At rest | Notes                                            |
|--------------------|---------|--------------------------------------------------|
| Firebase Hosting   | $0      | far under 10 GB / 360 MB-day                      |
| Cloud Run          | $0      | scale-to-zero; ~1–2s cold start on first request |
| Artifact Registry  | ~pennies| bounded by cleanup policy                        |
| **Total**          | **~$0** | contingent on billing linked + $1 budget tripwire|

---

## Phase 0 — GCP project & prerequisites (one-time, manual)

1. Create the project and link the existing billing account.
2. Enable Firebase on the project.
3. Auth `gcloud` + application-default credentials (so the Terraform `google`
   provider picks them up, the way `AWS_PROFILE` works for the AWS stack).
4. Decide: start with the free `*.web.app` URL (instant, no DNS); add a custom
   domain later if wanted.

See "Init commands" at the bottom for the exact sequence.

## Phase 1 — State backend bootstrap `infra/dev-gcp/bootstrap/`

Mirror of `infra/prod-aws/bootstrap`:

- `google_storage_bucket` for TF state — versioning on, uniform bucket-level
  access, `prevent_destroy`.
- `local_file` writing `../backend.tf` with the `gcs` backend block (same
  generated-backend pattern already used on the AWS side).
- Applied once, manually.

## Phase 2 — Core stack `infra/dev-gcp/`

Providers `google` + `google-beta`, `var.project`, region `us-central1`.

- `google_project_service` for: `run`, `artifactregistry`, `firebase`,
  `firebasehosting`, `iam`, `cloudresourcemanager`, `sts`, `iamcredentials`,
  `billingbudgets`.
- **Artifact Registry** Docker repo + **cleanup policy** (keep last N images).
- **Cloud Run v2 service** (`us-central1`): `min_instances = 0`, small
  `max_instances`, 1 vCPU / 512 MiB, image tag from `var.image_tag` (bumped by
  CI, same pattern as `image.auto.tfvars`). No app change needed — Cloud Run
  injects `PORT=8080` and the app already reads `PORT`; `/healthz` is the
  startup probe.
  - **Verify:** the app binds `0.0.0.0:$PORT`, not `localhost`.
- **IAM:** `allUsers` → `roles/run.invoker`.
- **Firebase:** `google_firebase_project` + `google_firebase_hosting_site`
  (google-beta).
- **Budget:** `google_billing_budget` at **$1** with threshold alerts (GCP-side
  mirror of the AWS tripwire). Custom-email alerts need a Cloud Monitoring
  notification channel resource.

## Phase 3 — Static + rewrite deploy (Firebase CLI)

- `firebase.json`: `public: "webapp"`, rewrite `/api/**` → the Cloud Run
  service (`us-central1`), catch-all → `/index.html`. Preserves the APP-SPEC
  same-origin relative-fetch contract with zero app changes.
- Deployed by `firebase deploy --only hosting` in CI.

> **Deferred, not blocked:** Terraform *can* own this later. Generating
> `firebase.json` via `local_file` would be trivial (we already do that kind of
> file-gen in `infra/prod-aws/bootstrap`). The only genuinely fiddly part is uploading
> static *content* as a `google_firebase_hosting_version` (per-file hash +
> API populate), so content deploy stays on the CLI for now. Revisit if we
> want the rewrite config under Terraform.

## Phase 4 — CI/CD (GitHub Actions + Workload Identity Federation)

Keyless, mirroring the AWS OIDC design:

- `google_iam_workload_identity_pool` + `_provider` (GitHub OIDC),
  attribute-scoped to this repo (analog of the AWS `job_workflow_ref` scoping).
- Least-privilege service accounts (echoing the 4-role AWS split):
  - *push* SA — Artifact Registry writer.
  - *deploy* SA — Cloud Run admin + service-account user.
  - *frontend* SA — Firebase Hosting admin.
- Workflows, parallel to the AWS ones:
  - `gcp-build-push` — on `app/`/Dockerfile push → build, push to Artifact
    Registry, open a PR bumping the image tag.
  - `gcp-apply` — on merge → `terraform apply`, rolling the Cloud Run revision.
  - `gcp-frontend` — on `webapp/` push → `firebase deploy --only hosting`.

## Phase 5 — Docs

- README: live `*.web.app` link up top + a "reference AWS stack, apply in
  ~30 min, tear down after" section.
- Update `CLAUDE.md` architecture section. Leave `docs/ARCHITECTURE.md` alone
  (human-authored — flag additions separately per its own rule).

## Sequencing

Phase 0 is manual (~15 min). Phases 1→2→3→4→5 in order; each is independently
testable (curl the Cloud Run URL before Hosting is wired; load `*.web.app`
before CI exists).

## Open decisions

- Project ID.
- Naming: "live demo" vs "dev".
- Default `*.web.app` URL now vs custom domain.
</content>
</invoke>
