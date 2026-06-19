# PRD: GitOps Practices on VMs

| Field         | Value                                 |
| ------------- | ------------------------------------- |
| Status        | Draft v1                              |
| Author        | Simon Fong                            |
| Last updated  | 2026-06-15                            |
| Companion doc | [plan.md](plan.md) - technical design |
| Project type  | Portfolio / personal project          |

## 1. Summary

A demonstration of **GitOps applied to VM-based deployment** on AWS EC2. A Go
RESTful API is rolled out across two app VMs behind an nginx load balancer,
using Jenkins + Ansible to perform progressive (canary) deployment with
automatic rollback on health-check failure. All deployment state lives in a
single Git repository.

The deliverable is a working AWS environment plus a public GitHub repository
that a hiring manager or engineer can clone, read, and (with their own AWS
account) reproduce end-to-end in under 30 minutes.

## 2. Background and Motivation

Most GitOps content online targets Kubernetes + ArgoCD / Flux. Real industries
- banks, insurers, telcos, government - still run substantial workloads on
plain VMs and are unlikely to migrate soon. Roles in those environments expect
candidates who can articulate GitOps principles **without** assuming a
container orchestrator.

This project exists to fill that gap in the author's portfolio. A companion
project (separate repo) covers Kubernetes + ArgoCD; this one deliberately
covers the VM path so the portfolio shows both delivery models.

## 3. Goals

### 3.1 Primary goals (must-have for v1)

| ID  | Goal                                                                                                                                    |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | Demonstrate the four GitOps tenets (SoT, declarative state, automated reconciliation, observability of state) without using Kubernetes. |
| G2  | Show a working canary rollout (20% → 50% → 100%) driven by nginx weight changes.                                                        |
| G3  | Show automatic rollback when a release fails its health check during canary.                                                            |
| G4  | Make the entire stack reproducible from `terraform apply` + `git push` - no AWS console clicks for deployment.                          |
| G5  | Be presentable as a portfolio artifact: clean README, topology diagram, recorded demo.                                                  |

### 3.2 Secondary goals (nice-to-have, v1 if time allows)

- A short demo video / asciinema cast embedded in the README.
- A "future work" section in the README that signals awareness of v2 gaps
  (Prometheus, TLS, secrets management).

### 3.3 Non-goals

- This is **not** a production-grade deployment system. Single-controller, no
  HA Jenkins, no multi-region.
- Not a Docker / container project. The application is a static Go binary by
  intentional design (see plan.md "Context and Positioning").
- Not a benchmarking project - no load testing, no performance targets beyond
  "responds to requests."
- Not a security project - no TLS, no secrets manager, no audit logging.

## 4. Target Audience

| Audience                     | What they should take away                                                   |
| ---------------------------- | ---------------------------------------------------------------------------- |
| Hiring managers / recruiters | "This candidate understands GitOps as a concept, not just an ArgoCD button." |
| Platform / DevOps engineers  | "The repo layout, pipeline split, and rollback design are sound for VM ops." |
| The author (future self)     | A working reference for VM-based deployment patterns to revisit later.       |

## 5. User Stories

Written from the perspective of an operator using the system (the role the
project is demonstrating competence in).

- **U1 - Release a new version.** As an operator, I edit `app/VERSION`, push,
  wait for the build pipeline, then edit `deploy/release.yaml` and push, so
  that the new version rolls out progressively without me touching any VM.
- **U2 - Observe rollout state.** As an operator, I curl the LB and see the
  `version` field shift as the canary weight increases, so that I can verify
  the rollout is progressing.
- **U3 - Survive a bad release.** As an operator, I push a release that fails
  `/healthz`, and the system reverts traffic and the canary binary back to the
  prior version without my intervention, so that user impact is limited to
  the canary slice during the failure window.
- **U4 - Reproduce the environment.** As a reviewer, I clone the repo, run
  `terraform apply`, and have a working four-VM environment, so that I can
  evaluate the project without taking the author's word for it.
- **U5 - Understand the design.** As a reviewer, I read the README and
  `docs/plan.md` and understand the topology and the rollback flow within ten
  minutes, so that I can judge the author's design clarity.

## 6. Functional Requirements

### 6.1 Application

| ID   | Requirement                                                                                                                  |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- |
| FR-1 | A Go HTTP service (built with `gin`) exposing `GET /` returning `{"app":"VM GitOps Practices","version":"<v>"}`.              |
| FR-2 | A Go HTTP service exposing `GET /healthz` returning `200 ok` when healthy.                                                   |
| FR-3 | The `version` value is baked into the binary at build time via `-ldflags`, sourced from `app/VERSION`.                       |
| FR-4 | A failure-injection switch is baked into the binary at build time via `-ldflags -X main.healthy=false`. When the flag is not `"true"`, `/healthz` returns `500`. Default `"true"`. Toggling the flag = a code/release commit, preserving the GitOps story. |
| FR-5 | The service binds to `:8080`, runs as a non-root `appuser` under `systemd`, and shuts down gracefully on `SIGTERM` (drains in-flight requests within 10s before exiting) so `systemctl restart` during a canary phase does not drop connections. |
| FR-5a | Request logging is provided by `gin.Default()`'s default logger - one structured line per request to stdout, captured by `journalctl`. Lets the demo show per-VM traffic shifts during canary phases. |

### 6.2 Infrastructure

| ID   | Requirement                                                                                                                                     |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-6 | Terraform under `infra/` provisions four EC2 instances in **region `ca-central-1`**, AMI **Amazon Linux 2023**: 1 controller (`t3.small`), 1 LB (`t3.micro`), 2 app (`t3.micro`). |
| FR-7 | Terraform creates a security group permitting: SSH from controller to LB+app, HTTP :80 from internet to LB, HTTP :8080 from LB to app VMs only. |
| FR-8 | An Ansible bootstrap playbook installs nginx on the LB (via `dnf`), installs Jenkins on the controller (via the Jenkins yum repo + `dnf`, running as a `systemd` service - **not** in Docker), and creates `appuser` and `/opt/app/` on app VMs. Idempotent. |
| FR-8a | An Ansible static inventory `ansible/inventory.ini` lists the four hosts with hardcoded private IPs and AL2023's default user (`ec2-user`). Regenerated by hand after any Terraform reprovision. |

### 6.3 Source of Truth

| ID    | Requirement                                                                                                                                                                       |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-9  | `deploy/release.yaml` declares: `version`, ordered list of `phases` (each with `weight_canary` and `hold_seconds`), `canary_host`, `stable_hosts`, and `health_check` parameters. |
| FR-10 | No deployment state may be set outside Git. Specifically: no manual `scp`, no console-edited nginx config, no SSH-set environment variables.                                      |

### 6.4 Build Pipeline

| ID    | Requirement                                                                                    |
| ----- | ---------------------------------------------------------------------------------------------- |
| FR-11 | Polls `main` for changes under `app/` via Jenkins SCM polling at ~30s interval.                |
| FR-12 | Runs `go vet` and `go test`. Fails the build on either.                                        |
| FR-13 | Produces a versioned binary artifact named `gitops-api-<version>` stored on the controller VM. |
| FR-14 | Does **not** deploy. Produces only the artifact.                                               |

### 6.5 Deploy Pipeline

| ID    | Requirement                                                                                                                                                           |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-15 | Polls `main` for changes under `ansible/` or `deploy/` via Jenkins SCM polling at ~30s interval.                                                                       |
| FR-16 | Reads `deploy/release.yaml`; aborts with a clear error if the artifact for the declared `version` is not present on the controller.                                   |
| FR-17 | Captures a pre-deploy state snapshot (current canary version + current nginx weights) for rollback.                                                                   |
| FR-18 | Deploys the new binary to the canary host: copy to `/opt/app/releases/<version>/`, swap `/opt/app/current` symlink, restart `gitops-api.service`.                     |
| FR-19 | For each phase: templates nginx upstream weights, reloads nginx (`nginx -s reload`), runs a health-check loop.                                                        |
| FR-20 | Health-check loop curls the configured URL every `interval_seconds`. Three consecutive non-200 responses trigger rollback.                                            |
| FR-21 | On successful 100% phase: deploys the new binary to `stable_hosts` so all VMs converge on the new version.                                                            |
| FR-22 | On health-check failure: invokes `rollback.yml`, which sets canary weight to 0, swaps the canary symlink back, restarts the service, and marks the Jenkins build red. |

### 6.6 Repository Layout

Repository layout is fixed as specified in [plan.md §Repository Layout](plan.md). Changes to layout require a plan update first.

## 7. Non-Functional Requirements

| ID    | Requirement                                                                                                                                                      |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NFR-1 | A canary rollout MUST NOT drop in-flight connections. Two mechanisms: (a) nginx weight changes use `nginx -s reload`, not restart; (b) the Go service handles `SIGTERM` with `http.Server.Shutdown` and a 10s drain timeout (see FR-5). |
| NFR-2 | The canary symlink swap MUST be atomic on the target VM. (Achieved by `ln -sfn` → `mv`, not `rm` + `ln`.)                                                        |
| NFR-3 | All Ansible playbooks MUST be idempotent - re-running with no Git change MUST produce no VM changes.                                                             |
| NFR-4 | A reviewer with an AWS account SHOULD be able to go from `git clone` to a working LB URL in under 30 minutes, following only the README.                         |
| NFR-5 | Total monthly AWS cost in the default config SHOULD stay within the EC2 free tier where possible; absolute ceiling \$15 USD/month when all four VMs are running. |
| NFR-6 | The end-to-end deploy pipeline (commit → 100% promoted) SHOULD complete in under 5 minutes on the happy path so the demo is watchable.                           |

## 8. Acceptance Criteria

The project is "done" (v1 shippable as portfolio) when all of the following
pass in a clean environment:

| ID   | Acceptance test                                                                                                                                                                                                                                                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC-1 | `terraform apply` from a clean state provisions 4 EC2 instances and outputs the LB public IP.                                                                                                                                                                          |
| AC-2 | The Ansible bootstrap playbook applied to a fresh fleet leaves the LB serving nginx default and app VMs with `appuser` and `/opt/app/` in place.                                                                                                                       |
| AC-3 | Committing `app/VERSION = 0.1.0` and pushing produces a build artifact `gitops-api-0.1.0` on the controller VM.                                                                                                                                                        |
| AC-4 | Committing `deploy/release.yaml` with `version: 0.1.0` and pushing results in `curl <LB>/` returning `version: "0.1.0"` from both app VMs (verified by repeated curls).                                                                                                |
| AC-5 | Bumping to `0.2.0` (build + release commits) produces visible weight shifts: during the 20% phase, ~1-in-5 curls to `<LB>/` return version `0.2.0`; during 50%, ~1-in-2; after promotion, 100%.                                                                        |
| AC-6 | Pushing a release built with `-X main.healthy=false` causes the deploy pipeline to detect failure within ~15s of the canary going live, run rollback, and leave `curl <LB>/` reporting the prior version on every call. The Jenkins build for the bad release is red. |
| AC-7 | Running `ansible-playbook deploy.yml` a second time with no Git change reports zero changed tasks (idempotency).                                                                                                                                                       |
| AC-8 | The README contains: topology diagram, repo layout, the demo script (5 steps from plan.md §Demonstration Script), the explicit "out of scope" list, and a link to `docs/plan.md`.                                                                                      |

## 9. Milestones

Mapped to the phased build order in `plan.md`. Each milestone produces something
demonstrable to avoid a big-bang integration.

| Milestone | Maps to plan.md phase          | Exit criterion                                                                      |
| --------- | ------------------------------ | ----------------------------------------------------------------------------------- |
| M1        | A (App + infra skeleton)       | Go binary runs on an app VM and serves `/` with a correct version.                  |
| M2        | B (Static nginx LB)            | `curl <LB>/` round-robins between both app VMs.                                     |
| M3        | C (Build pipeline)             | A commit to `app/` produces a versioned artifact on the controller.                 |
| M4        | D (Deploy pipeline, no canary) | A commit to `deploy/release.yaml` deploys the same version to both VMs in lockstep. |
| M5        | E (Canary + health check)      | Bumping version triggers visible 20→50→100 weight progression with health gating.   |
| M6        | F (Rollback)                   | The failure-injection demo path works end-to-end.                                   |
| M7        | G (Polish)                     | README, diagram, recorded demo, "future work" section all present.                  |

## 10. Risks and Mitigations

| Risk                                                            | Likelihood | Impact | Mitigation                                                                                |
| --------------------------------------------------------------- | ---------- | ------ | ----------------------------------------------------------------------------------------- |
| Forgotten running EC2 instances drive up AWS bill               | Medium     | Medium | Document `terraform destroy` prominently; consider a scheduled stop.                      |
| Jenkins polling adds up to 30s latency before pipeline starts   | Low        | Low    | Accepted trade-off (see §11 decision 4); README notes webhook as v2.                      |
| `curl /healthz` as the sole signal misses real-traffic 5xx      | High       | Low    | Acknowledged explicitly in README as a v1 trade-off; Prometheus listed as v2 future work. |
| Reviewer cannot run AWS but wants to evaluate                   | High       | Low    | Recorded demo + clear code structure so static review is meaningful.                      |
| Ansible playbook non-idempotency surfaces during demo           | Medium     | Medium | NFR-3 + an explicit "re-run with no change" check in AC-7.                                |
| Scope creep toward adding Docker / K8s / Prometheus mid-project | Medium     | High   | "Non-goals" and "out of scope" sections are load-bearing - revisit before any addition.   |
| Terraform reprovision changes private IPs, breaking static inventory | Medium | Medium | Document "after reprovision, regenerate `inventory.ini` from Terraform output" in the runbook. |

## 11. Resolved Decisions

Decided 2026-06-15. Captured here so reviewers see the rationale, not just
the outcome.

| #   | Question                          | Decision                                              | Rationale                                                                                                                                                |
| --- | --------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Jenkins install shape             | **Native package install on the controller EC2.**     | Project's point is VM-native operations. Running Jenkins itself in Docker would undermine that signal. Treat Jenkins as a long-lived system service.     |
| 2   | Ansible inventory mechanism       | **Static `inventory.ini` with hardcoded private IPs.** | Simpler, fewer moving parts, easier to read in a portfolio review. Dynamic inventory listed as v2 future work.                                          |
| 3   | AWS region and base AMI           | **Region `ca-central-1`. AMI: Amazon Linux 2023.**    | Author is in Canada (lower latency for live demo). AL2023 is current Amazon-blessed AMI, has `dnf`, and is the natural pairing with EC2-based portfolio. |
| 4   | Pipeline trigger                  | **Jenkins SCM polling (~30s interval).**              | Works behind NAT, no Jenkins ingress to expose, simpler security group story. Webhook listed as v2 future work.                                          |

### 11.1 Still open

1. **Does `deploy/last-good.yaml` get auto-committed by Jenkins?** Plan currently says yes (§Deploy Pipeline step 7), but auto-commits from CI complicate the "humans are the only writers to Git" story. Alternative: track last-good as a Jenkins build artifact (recorded per-build, kept on the controller VM filesystem) rather than in Git. **Decision needed before milestone M6 (rollback).**

## 12. Future Work (v2 ideas, not committed)

Listed here so reviewers see that v1 omissions are deliberate, not unknown.

- **Prometheus + a 5xx-rate query** as the rollback signal, replacing the
  single-endpoint `curl /healthz`.
- **Grafana dashboard** showing per-version request rate and error rate during
  rollouts.
- **TLS on the LB** via Let's Encrypt / cert-manager-equivalent.
- **Secrets management** via Ansible Vault or AWS SSM Parameter Store.
- **Webhook-based pipeline triggers** instead of SCM polling (v1 chose polling - see §11 decision 4).
- **Blue/green** rollout as an alternative to canary, selectable per release.
- **Dynamic Ansible inventory** keyed off EC2 tags (v1 chose static inventory - see §11 decision 2).
- **Slack / GitHub-status notifications** on rollout success and rollback.

## 13. References

- [docs/plan.md](plan.md) - full technical design (topology, repo layout, pipeline mechanics, systemd unit, demo script).
- Companion portfolio project: GitOps on Kubernetes with ArgoCD (separate repo).
