# Replacement Application Specification

## Purpose

This repository (`terraform-ecs-gitops`) is a reference implementation of a
container deployment pipeline: Terraform-managed AWS infrastructure, GitHub
Actions CI/CD, and a GitOps promotion flow where image tag bumps arrive as
reviewable pull requests carrying a `terraform plan` in the PR comments.

**The infrastructure is the deliverable. The application is a fixture.**

Its only jobs are to (1) exercise every routing path the infrastructure
defines, so that misconfiguration is visible rather than silent, and (2) be
small enough that a reader's attention stays on the pipeline. It replaces a
prior demo app that carried third-party branding; nothing of that app should
survive here.

The implementing agent has real creative latitude over *what the app does* —
see §6. It has none over §2.

See `docs/PRIORITIES.md` for why: the frontend visual isn't a placeholder to
be filled in adequately and moved past. Experimenting with genuine
LLM-driven art is one of this project's actual goals, on equal footing with
the infrastructure work, not a courtesy afforded to the implementing agent.
Treat §6 accordingly.

---

## 1. What the infrastructure already assumes

Two origins sit behind one CloudFront distribution:

```
                    CloudFront
                   /          \
       default    /            \  /api/*
                 v              v
        S3 (static, OAC)    ALB (private subnet, VPC origin)
                                     |
                                     v
                            ECS Fargate task
```

The frontend is served from S3 as static objects. The backend runs as a single
Fargate task in a private subnet with no public IP and no NAT — it reaches ECR
and CloudWatch through VPC interface endpoints. Same-origin is achieved by
CloudFront, not by CORS, so the frontend calls the backend with **relative
URLs** and no CORS middleware is needed anywhere.

---

## 2. Hard contract (do not change these without changing Terraform)

| Constraint | Why it exists |
|---|---|
| Backend reads `PORT` from env, defaults to `8080` | Task definition sets `PORT`; `container_port` var and the target group both key on 8080 |
| `GET /healthz` returns `200` with no auth | ALB target group health check. Must respond before the task is registered |
| All browser-facing backend routes live under `/api/` | Single CloudFront `ordered_cache_behavior` with `path_pattern = "/api/*"` |
| `/healthz` sits **outside** `/api/` | Deliberate: the health endpoint is unroutable from the internet, reachable only from inside the VPC |
| `/api/*` responses must not be cached | `/api/runtime` reports live task identity and uptime. If CloudFront cached it, a refresh after a deploy would show the *old* commit SHA and the verification demo would silently lie. `CachingDisabled` stays on that behavior |
| Frontend has **no build step** | The frontend deploy workflow is `aws s3 sync webapp/ s3://...` plus an invalidation. A bundler would force a build job, a lockfile, and a toolchain into an otherwise trivial workflow. Vendored `<script>` libraries are fine and do not violate this — see §6 |
| Frontend has no client-side routing or deep links | CloudFront relies on `default_root_object = "index.html"`. Deep links would require custom 403/404 → `index.html` error mappings in Terraform |
| Container is single-process, stateless, listens on one port | `awsvpc` networking, one container per task, no sidecars, no volumes |

Anything in this table that the app violates becomes an infrastructure change,
which defeats the point of a drop-in replacement.

---

## 3. Recommended stack: Go

Not required, but strongly recommended over the Haskell original:

- **Build time.** The prior image built from `fpco/stack-build` and repeatedly
  exhausted the ~14 GB usable disk on `ubuntu-latest` runners, requiring
  explicit deletion of preinstalled toolchains as a mitigation. A Go build is
  seconds and hundreds of megabytes.
- **Image size.** A static binary on `gcr.io/distroless/static` or `scratch`
  lands around 10–15 MB. Faster ECR pushes, faster cold pulls through the VPC
  endpoint, and a genuinely small attack surface — all of which are points
  worth making in `ARCHITECTURE.md`.
- **No dependency manifest required.** The whole backend fits in the standard
  library. `net/http` is enough; no framework, no `go.sum` churn, no
  third-party supply chain to explain.
- **Conventional.** A reader evaluating the pipeline shouldn't have to parse
  Servant type-level routing to confirm the app is boring.

If you deviate, the replacement must still produce a single static binary or
an equivalently small runtime image, and must not require a package manager at
container start.

---

## 4. Backend

Standard library only. Structured JSON logs to stdout (CloudWatch picks these
up via the `awslogs` driver). Graceful shutdown on `SIGTERM` — ECS sends it
during rolling deploys, and handling it keeps deploys from dropping requests.

### Routes

**`GET /healthz`** — unauthenticated, returns `200` and a short plain-text or
JSON body. Cheap: no downstream calls, no I/O. This is the liveness signal;
if it depends on anything, a transient failure becomes an unhealthy task.

**`GET /api/build`** — unauthenticated. Returns build-time facts compiled into
the binary: image tag, commit SHA, build timestamp, Go version.

**`GET /api/runtime`** — unauthenticated. Returns facts only the running task
knows: task ID (short form), availability zone, hostname, process uptime,
request count. Source these from the ECS task metadata endpoint at
`$ECS_CONTAINER_METADATA_URI_V4` (Fargate injects this automatically; append
`/task` for task-level data). **Degrade gracefully** when the variable is
absent so the container still runs under plain `docker run` locally.

There is deliberately **no authentication.** The original app's login form
existed to gate its data; this app has no data worth gating, and a login
screen whose credentials are printed on the page next to it is ceremony, not
security. Removing it also means a visitor lands on the deployed URL and sees
the thing working immediately, with nothing to fumble.

Say so explicitly in `ARCHITECTURE.md` rather than leaving it unremarked —
"no auth because there is nothing to protect" is a defensible design statement;
silence reads as an oversight. Note alongside it what *would* change if a real
authenticated route were added: an `AllViewer` origin request policy on the
`/api/*` behavior so CloudFront forwards the `Authorization` header to the VPC
origin, and secrets sourced via `valueFrom` from Secrets Manager or SSM rather
than plaintext task-definition env vars. That keeps the knowledge in the repo
without staging a fake login to demonstrate it.

### Why `/api/runtime` earns its place

It is the one thing a static S3 frontend structurally cannot answer. If the
CloudFront `/api/*` behavior, the VPC origin, the ALB, the security groups,
the target group, or the task itself are misconfigured, this endpoint fails
and the page says so. It turns the whole routing chain into something you can
verify by loading a URL — and it doubles as deploy verification: after merging
an image-tag bump PR, refresh and watch the commit SHA change.

---

## 5. Build metadata plumbing

`/api/build` needs values injected at image build time.

**Dockerfile:** accept `ARG GIT_SHA`, `ARG IMAGE_TAG`, `ARG BUILD_TIME` and
pass them via `-ldflags "-X main.gitSHA=$GIT_SHA ..."`. Provide sensible
defaults (`dev`, `unknown`) so a bare `docker build` still works.

**`ci-build-push.yaml`:** add a `build-args:` block to the
`docker/build-push-action` step supplying `${{ github.sha }}` and the
already-computed short SHA. This is the one workflow change the app requires;
it's additive and doesn't alter the existing tagging or PR-opening logic.

Keep the args out of the cache key path where possible — a changing
`BUILD_TIME` on every build will invalidate layers if it's introduced too
early in the Dockerfile. Put the `ARG` declarations in the final stage, after
the compile step, or accept a rebuild of the last layer only.

---

## 6. Frontend — constrained shell, open interior

### Fixed

- **No npm, no bundler, no ES-module import graph.** The constraint is on the
  *toolchain*, not on dependencies. `webapp/` must remain a directory of files
  that `aws s3 sync` can copy verbatim to a bucket.
- **Libraries are allowed, vendored.** One graphics library is welcome — see
  below. Commit the minified file into `webapp/`, pin the version in the
  filename (`three.r128.min.js`), and load it with a plain `<script>` tag.
  The original's CanvasJS was the right instinct: a large file no reader
  examines, buying a very small call site that they do.
- **Vendor the file; do not use a CDN.** A CDN `<script>` tag makes the
  deployed site depend on a third-party origin staying up, undercuts the
  "everything is served from S3 behind CloudFront" story the repo is telling,
  and complicates any future CSP. A vendored copy is synced, cached, and
  served by the same distribution as everything else, and the page works with
  no external network dependency.
- **One library, not three.** Pick the one that fits the idea and stop.
- Drop jQuery. `fetch` and `querySelector` cover everything the app does, and
  keeping it would be the one dependency that genuinely earns an eye-roll.
- Single page. No routing.
- All backend calls use relative paths (`fetch('/api/build')`).
- Must render something meaningful *before* login: the build and runtime info
  from the unauthenticated endpoints. A visitor who never logs in should still
  see that the pipeline works.
- Explain itself. A short header stating what this repository is and that the
  app is a fixture for the deployment pipeline. Someone landing on the
  deployed URL cold should understand within a few seconds.
- Handle backend failure visibly — if `/api/*` returns non-200 or times out,
  say so on the page rather than failing silently. A broken origin should look
  broken.

### Open — this part is yours

Build something worth looking at. The repository is a serious artifact and the
app is a fixture, but a fixture that is dull on purpose is a missed
opportunity: this is the one part of the project where the implementing agent
gets to make an aesthetic decision, and it should be made with some
conviction rather than hedged into a gray box with a version number in it.

This isn't a rhetorical nudge toward "add some polish." The author is
deliberately using this call site as an LLM-driven-art exercise — make an
actual aesthetic choice and commit to it, the way an artist would, rather than
converging on the safest generic option a model tends to default to.

**The one structural requirement: seed the visual from the deployed commit
SHA.** Fetch `/api/build`, hash the SHA into a numeric seed, and drive the
piece deterministically from it. This matters beyond novelty — it is what
replaces the removed auth route as proof that the routing is load-bearing.
The art cannot render its correct form without a working path through
CloudFront, the VPC origin, the ALB, and the task. If the backend is
unreachable, the page should say so plainly instead of falling back to a
random seed and looking fine while being broken.

The payoff: every deploy has a visible fingerprint. Merge an image-tag bump,
watch the plan, refresh, and the picture is different. That is a more
memorable demonstration of a GitOps promotion flow than any diagram.

Directions, not requirements:

- **Three.js** — a slowly rotating solid whose geometry, subdivision, material
  and palette all derive from the seed. Raymarched or shader-based work is
  fair game; a fragment shader is a single template literal, no build step
  implied.
- **p5.js** — flow fields, reaction-diffusion, Perlin landscapes, generative
  poster compositions. The most direct route to something that looks
  deliberately *designed* rather than merely computed.
- **Matter.js** — a small physics scene assembled from the seed, settling into
  a different arrangement per deploy. Motion that resolves rather than loops
  is unusual and reads well.
- **Plain canvas, no library** — still entirely valid if the idea is simple
  enough. Classic demoscene territory: plasma, metaballs, tunnel, raster bars,
  starfield, Lissajous curves, scrolltext. Forty lines can be genuinely
  striking, and the demoscene lineage suits a self-describing build artifact.

Keep the *call site* small even if the library is large. CanvasJS earned its
570 KB by reducing the interesting code to thirteen readable lines; that
tradeoff is the model. A reader should be able to open `demo.js`, understand
the idea quickly, and return their attention to the Terraform — total bytes
shipped is not the metric, comprehension time is.

Have the pipeline panel — uptime, request count, task ID, polling live — coexist
with the visual rather than replace it, so a rolling deploy is observable in
real time as the task ID changes underneath a running animation.

### Suggested layout

```
webapp/
  index.html
  index.css
  app.js               # fetch, pipeline panel, error states
  demo.js              # the visual — seeded, swappable, self-contained
  vendor/
    three.r128.min.js  # pinned, vendored, committed
  favicon.ico
```

Keeping the visual in its own file means it can be replaced later — or a
second one added and switched between — without disturbing anything that talks
to the backend. `demo.js` should expose roughly one entry point taking a seed
and a container element, and know nothing about `fetch`.

---

## 7. Terraform changes required

Beyond renaming:

1. `ordered_cache_behavior.path_pattern`: `"/report*"` → `"/api/*"`
2. `aws_lb_target_group.app.health_check.path`: `"/"` → `"/healthz"`
3. On the `/api/*` behavior, **remove** `origin_request_policy_id` (the
   `AllViewer` managed policy). It existed to forward the `Authorization`
   header to the origin; with no authenticated route, nothing needs
   forwarding. Omitting it entirely is the correct default — CloudFront then
   forwards only what the cache policy specifies.
4. On the same behavior, narrow `allowed_methods` from the full
   `GET/HEAD/OPTIONS/PUT/POST/PATCH/DELETE` set to `["GET", "HEAD"]`. Every
   `/api/` route is a read.

**Keep `cache_policy_id` set to `CachingDisabled`.** It is now more clearly
justified, not less: `/api/runtime` reports live task identity and uptime, and
caching it would break deploy verification in the most confusing possible way —
the page would show a stale commit SHA and look perfectly healthy doing it.

Also **delete** the Dockerfile stub-webapp step
(`mkdir -p webapp && touch webapp/index.html`) — it existed only because the
Haskell app served `/` from a directory that had moved to S3. A real health
endpoint removes the need for the workaround entirely, which is worth a line
in the write-up: the original had no health endpoint and the ALB checked `/`
as a proxy for one.

---

## 8. Renaming — done

Every reference to the original take-home naming has been replaced throughout
`infra/`, the workflow files, and the READMEs. Kept for reference — these are
the couplings that made it more than a find-and-replace, worth knowing before
touching any of these identifiers again:

- `provider.default_tags` value **and** the matching `TagFilters` value in
  `aws_resourcegroups_group` must stay identical or the resource group
  silently matches nothing
- The log group, task family, and container name must all agree — the
  container name also appears in `aws_ecs_service.load_balancer.container_name`,
  and a mismatch there is a deploy-time failure, not a plan-time one
- The ECR repository name also appears in the `tags:` of the build step in
  `ci-build-push.yaml`
- `variables.tf`'s `github_repo` default must match wherever this actually
  gets published, or the OIDC trust policies won't authorize any workflow
- README, and the removal of `package.yaml`, `*.cabal`, `stack.yaml*`,
  `brittany.yaml`

Note that renaming resources against existing state means destroy/recreate for
most of them. Since this is a fresh repository and a fresh state key anyway,
apply into new state rather than trying to migrate.

---

## 9. Before making the repository public

- **`backend.tf` hardcodes the AWS account ID** in the bucket name. Terraform
  backend blocks can't interpolate variables, so this isn't fixable without a
  partial backend config injected via `-backend-config=` flags at init time —
  considered and deliberately not done. The account ID already appears in
  plaintext throughout the `terraform plan` output posted publicly by
  `infra-plan.yaml` on every deploy PR (S3 bucket names, IAM policy
  documents — anything built with `format()` rather than server-assigned, so
  it renders even on a from-scratch `apply`). Protecting it in `backend.tf`
  alone while every deploy PR exposes it anyway would be inconsistent effort
  for information AWS doesn't treat as secret in the first place. If this
  ever needs revisiting, the real lever is redacting the account ID out of
  what `infra-plan.yaml` posts, not `backend.tf`.
- `alert_email` default in `variables.tf` is a personal address. Make it a
  required variable with no default.
- Confirm no planning documents referencing the original exercise, company, or
  reviewers are carried over.
- Initialize as a fresh repository — new directory, copy files, `git init`.
  Do not filter history; rewritten history leaves orphaned objects and is easy
  to get subtly wrong.

---

## 10. Non-goals

Do not add: a database, a session store, authentication, user registration,
client-side routing, a UI framework, a CSS framework, WebSockets, server-side
rendering, multiple containers, or any dependency that arrives through a
package manager rather than as a committed file.

The single vendored graphics library from §6 is the deliberate exception. It
is permitted because it buys a small call site and costs nothing but bytes on
a CDN that is already there. A second one buys nothing.

Everything else on that list makes the fixture compete with the infrastructure
for the reader's attention, and several would force real Terraform changes.

If a proposed feature requires touching anything in §2, the answer is no.
