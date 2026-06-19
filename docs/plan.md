# Project: GitOps Practices on VMs

## Context and Positioning

A VM-based GitOps demonstration: a Go RESTful API deployed to AWS EC2 instances
via Jenkins + Ansible, with progressive (canary) rollout and automatic rollback
on failure. The Git repository is the single source of truth for both
application code and deployment configuration.

This project is the deliberate counterpart to a separate Kubernetes + ArgoCD
GitOps portfolio project. Together they cover both delivery models a hiring
team might care about:

| Project       | Platform | Delivery tool            | Artifact            |
| ------------- | -------- | ------------------------ | ------------------- |
| GitOps on K8s | K8s      | ArgoCD (pull)            | Container image     |
| GitOps on VMs | EC2 VMs  | Jenkins + Ansible (push) | Go binary + systemd |

No Docker is used for the application. The artifact is a static Go binary
managed by `systemd` - the canonical shape for VM-native deployment.

## GitOps Tenets - How They Map Here

1. **Single Source of Truth.** All app code (`app/`) and all deployment
   configuration (`ansible/`, `deploy/release.yaml`) live in this monorepo on
   `main`.
2. **Declarative Desired State.** `deploy/release.yaml` declares the version
   and canary phases. Operators change state by committing to this file, not
   by SSH-ing to VMs.
3. **Automated Reconciliation.** Jenkins polls `main`; on change to relevant
   paths, the appropriate pipeline runs Ansible to converge VMs to the
   declared state.
4. **Progressive Delivery.** Canary rollout: 20% → 50% → 100%, with a hold
   period at each phase for health checking.
5. **Auto-Rollback.** A failed health check during any phase reverts nginx
   weights and the symlinked binary on the canary VM to the prior version.

## Topology - 4 EC2 instances

```
              ┌─────────────────────┐
              │   Controller VM     │
              │  - Jenkins          │
              │  - Ansible          │
              │  - Git polling      │
              └──────────┬──────────┘
                         │ SSH (Ansible)
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   ┌─────────┐      ┌─────────┐      ┌─────────┐
   │  LB VM  │      │ App VM1 │      │ App VM2 │
   │  nginx  │◄────►│  Go API │      │  Go API │
   │ (split) │      │ systemd │      │ systemd │
   └────┬────┘      └─────────┘      └─────────┘
        ▲
        │ HTTP from clients
```

- **Controller VM** (`t3.small`): Jenkins (Docker or native - operational
  choice, not part of the deploy story), Ansible, SSH keys to the other VMs.
- **LB VM** (`t3.micro`): nginx with weighted upstream block. Public-facing.
- **App VM1, App VM2** (`t3.micro` each): one Go binary per VM, run as
  `systemd` service `gitops-api.service`. During canary, **App VM1 is the
  canary** and App VM2 stays on the stable version.

Provisioning is via Terraform (`infra/` directory) - included because
"clickops in the AWS console" undermines the source-of-truth story.

## Repository Layout

```
.
├── app/                     # Go RESTful API source
│   ├── main.go
│   ├── go.mod
│   └── VERSION              # human-edited, e.g. "0.2.0"
├── ansible/                 # Playbooks and roles
│   ├── inventory.ini        # references VM IPs (or uses dynamic inventory)
│   ├── deploy.yml           # app rollout playbook (canary-aware)
│   ├── rollback.yml         # rollback playbook
│   ├── nginx.yml            # nginx config + reload
│   └── roles/
│       ├── app/             # binary placement, systemd unit, symlink swap
│       └── nginx/           # weighted upstream template
├── deploy/
│   └── release.yaml         # declares: version, canary phases, target VMs
├── infra/                   # Terraform for EC2 + SG + key pair
│   └── main.tf
├── jenkins/
│   ├── Jenkinsfile.build    # app/ pipeline: build artifact
│   └── Jenkinsfile.deploy   # ansible/ + deploy/ pipeline: rollout
└── docs/
    ├── plan.md              # this document
    └── runbook.md           # how to demo / how to recover
```

## The RESTful API

Minimal, but structured so canary state is observable from outside:

| Method | Path       | Response                                                |
| ------ | ---------- | ------------------------------------------------------- |
| GET    | `/`        | `{"app":"VM GitOps Practices","version":"0.2.0"}`       |
| GET    | `/healthz` | `200 ok` when healthy; `500` when a failure flag is set |

The version string is read at build time from `app/VERSION` via Go `ldflags`
(`-X main.version=$(cat VERSION)`). This makes the version visible at runtime
without any config-file lookup - the binary is the source of its own truth.

`/healthz` includes a hidden failure switch baked in at build time via
`-ldflags "-X main.healthy=false"` so a broken release can be simulated by
committing a bad version and watching the rollback trigger. Required for the
demo. Default is `healthy=true`; a `healthy=false` build is the only way to
trip `/healthz` into returning 500.

## Source of Truth: `deploy/release.yaml`

```yaml
version: "0.2.0"
phases:
  - weight_canary: 20
    hold_seconds: 60
  - weight_canary: 50
    hold_seconds: 60
  - weight_canary: 100
    hold_seconds: 0
canary_host: app-vm1
stable_hosts: [app-vm2]
health_check:
  url: http://app-vm1:8080/healthz
  interval_seconds: 5
  failure_threshold: 3 # 3 consecutive non-200s trips rollback
```

Editing this file (e.g. bumping `version` after a build, or changing phase
weights) is how an operator declares intent. Jenkins reconciles.

## Two Pipelines

### Pipeline 1 - Build (`Jenkinsfile.build`)

Triggered by SCM polling on changes under `app/` on `main`.

1. Checkout.
2. `go vet ./...` and `go test ./...`.
3. `VERSION=$(cat app/VERSION)`; build binary with version baked in:
   `go build -ldflags "-X main.version=$VERSION" -o gitops-api ./app`.
4. Publish artifact to a Jenkins-managed location (filesystem on the
   controller VM is fine, e.g. `/var/lib/jenkins/artifacts/gitops-api-$VERSION`).
5. **Does not deploy.** The build pipeline only produces the artifact.

### Pipeline 2 - Deploy (`Jenkinsfile.deploy`)

Triggered by SCM polling on changes under `ansible/` or `deploy/` on `main`.

1. Checkout. Read `deploy/release.yaml`.
2. Verify the artifact for `version` exists on the controller. If not, fail
   with a clear "build pipeline has not produced this version" message.
3. **Snapshot current state** for rollback: record the currently-deployed
   version on canary host and current nginx weights.
4. **Pre-deploy canary**: `ansible-playbook deploy.yml --limit canary_host` -
   copies the new binary to `/opt/app/releases/$VERSION/`, atomically updates
   the `current` symlink, restarts `gitops-api.service`.
5. **Phase loop** (for each phase in `release.yaml`):
   a. Template nginx config with `weight_canary` and the complementary
   `weight_stable`. Reload nginx (`nginx -s reload`).
   b. Health-check loop: every `interval_seconds`, `curl -fsS $health_check.url`
   for `hold_seconds`. Count consecutive failures.
   c. If failures reach `failure_threshold`: **abort and roll back.**
6. **Promote**: once 100% phase passes, run `deploy.yml` against
   `stable_hosts` to bring them to the new version (so all VMs are now on the
   new version and ready to serve as stable for the next release).
7. Commit a `deploy/last-good.yaml` snapshot of the now-stable state (the
   rollback target for the next release).

### Rollback (`rollback.yml`)

Triggered by deploy pipeline on health-check failure.

1. Re-template nginx with `weight_canary: 0`, reload - stops sending traffic
   to canary immediately.
2. On canary host: swap the `current` symlink back to the prior version's
   directory, restart `gitops-api.service`.
3. Mark the Jenkins build as failed; exit non-zero.
4. (Optional v2: post to Slack / GitHub commit status.)

## Health Check / Rollback Signal - Jenkins-driven `curl`

No Prometheus in v1. The deploy pipeline itself runs the health probe via
`curl` from the controller VM against `app-vm1:8080/healthz` during each
canary phase. Three consecutive non-200 responses trips the rollback.

This is intentionally simple. Trade-offs to acknowledge in the README:

- **Pro**: zero extra infra; the signal is in the pipeline, easy to reason
  about, easy to demo.
- **Con**: only checks one endpoint, doesn't measure error rate from real
  traffic. A v2 with Prometheus + a 5xx-rate query is a natural follow-up
  and worth mentioning in the README as "future work."

## nginx Weighted Upstream - How Traffic Splits

`ansible/roles/nginx/templates/upstream.conf.j2`:

```nginx
upstream gitops_api {
    server app-vm1:8080 weight={{ weight_canary }};
    server app-vm2:8080 weight={{ weight_stable }};
}

server {
    listen 80;
    location / {
        proxy_pass http://gitops_api;
    }
}
```

`weight_stable` is computed as `100 - weight_canary`. Ansible templates this
on each phase change and runs `nginx -s reload` (graceful, no dropped
connections).

## systemd Unit - `gitops-api.service`

Stored as `ansible/roles/app/templates/gitops-api.service.j2`. Key properties
worth showing off:

- `ExecStart=/opt/app/current/gitops-api` - points at the symlink, so an
  atomic symlink swap + `systemctl restart` is the entire deploy step on the
  VM.
- `Restart=on-failure`, `RestartSec=2s`.
- Runs as a dedicated `appuser`, not root.
- `Environment=PORT=8080`.

Release layout on each app VM:

```
/opt/app/
├── releases/
│   ├── 0.1.0/gitops-api
│   └── 0.2.0/gitops-api
└── current -> releases/0.2.0
```

## Demonstration Script (for the portfolio README)

A working demo, in order:

1. `terraform apply` provisions 4 EC2 instances. Show the README diagram.
2. Bootstrap playbook (`ansible-playbook bootstrap.yml`) installs nginx on
   LB and creates `appuser` + `/opt/app/` on app VMs. (One-time.)
3. Commit `app/VERSION = 0.1.0`. Build pipeline runs, artifact produced.
4. Commit `deploy/release.yaml` with `version: 0.1.0`. Deploy pipeline runs
   the canary phases against an empty stable, promotes. Both app VMs now on
   0.1.0.
5. **Happy path:** bump `app/VERSION` to `0.2.0`, push. Build runs. Then
   bump `deploy/release.yaml` to `0.2.0`, push. Deploy runs all three phases,
   promotes. Show `curl LB/ | jq` returning `0.2.0`.
6. **Rollback path:** prepare a `0.3.0` build with `-X main.healthy=false` baked
   into the binary for the canary. Bump release to `0.3.0`. Deploy
   starts the 20% phase; `/healthz` returns 500; pipeline trips after 3
   failures; nginx weights revert; canary VM symlink swaps back to 0.2.0;
   Jenkins build red. Final `curl LB/` still returns 0.2.0.

Recording this as an asciinema cast or short video in the README is high
portfolio value.

## Phased Build Order

A suggested implementation order so you have a working slice early:

1. **Phase A - App and infra skeleton.** Go API with `/` and `/healthz`,
   `VERSION` file, `ldflags` build. Terraform for 4 EC2s. Bootstrap Ansible
   playbook. Manual `scp` + `systemctl` to confirm the binary runs on an
   app VM. _Output: API reachable on an app VM._

   **Sub-phases (this is where Ansible enters the picture):**

   - **A1 - Jump becomes the controller.** `user_data` on the jump instance
     installs `git`, `ansible-core`, `java-17`, and `jenkins` (native package,
     not Docker). Same script clones this repo to `/opt/gitops-vm/` and
     drops the fleet private key (`gitops-vm.pem`) into `~ec2-user/.ssh/`
     with `0400` perms so jump can SSH onward to the fleet. _Output: SSH
     to jump, `which ansible` works, `systemctl status jenkins` is
     active._

   - **A2 - Inventory rendering from Terraform.** Terraform writes
     `ansible/inventory.ini` via `local_file` using the live private IPs
     of lb / app-vm1 / app-vm2. This closes the Terraform→Ansible loop
     without dynamic inventory (deferred to v2 per
     [aws_design.md §10](aws_design.md)). _Output: `ansible -i
     ansible/inventory.ini all -m ping` from jump succeeds against all
     three fleet hosts._

   - **A3 - Bootstrap playbook.** `ansible/bootstrap.yml` runs once from
     jump against the fleet: creates the `appuser` account, scaffolds
     `/opt/app/{releases,current}/` on app VMs, writes the systemd unit
     stub, installs `nginx` on lb. _Output: `appuser` exists on all
     fleet hosts; nginx serves a 502 on lb (no upstream yet, expected)._

   ### Why Ansible runs on jump, not on the laptop

   Production ops shops don't run `ansible-playbook` from individual
   laptops - versions drift between operators, the audit trail lives in
   shell history, secrets sprawl everywhere. The canonical pattern is a
   **dedicated control node** that hosts Ansible, the inventory, and the
   CI/CD runner. All convergence flows from that one place. This project
   uses jump as the control node and Jenkins on jump as the trigger,
   matching the on-prem "utility server" model called out in
   [aws_design.md §2](aws_design.md).

   The laptop is read-only after `terraform apply`: edit code, push,
   open the Jenkins UI via SSH tunnel (`jenkins_tunnel` output in
   [04_output.tf](../infra/04_output.tf)), watch pipelines run.

   ### Bootstrap chicken-and-egg

   Ansible can't install itself on jump before jump exists. `user_data`
   is the one piece that has to be imperative (cloud-init script).
   Everything else from A2 onward is Ansible. This is exactly the
   "golden template" boundary [aws_design.md §7](aws_design.md) - the
   v2 Packer path will bake `user_data`'s install steps into an AMI,
   shrinking `user_data` to ~3 lines (clone repo, start Jenkins).
2. **Phase B - Static nginx LB.** nginx upstream with hardcoded 50/50 split.
   Confirm round-robin via `curl` and the `version` field. _Output: LB
   serves both VMs._
3. **Phase C - Jenkins build pipeline.** `Jenkinsfile.build` with polling on
   `app/`. _Output: commits to `app/` produce versioned artifacts._
4. **Phase D - Jenkins deploy pipeline (no canary yet).** `Jenkinsfile.deploy`
   that runs `deploy.yml` to push the artifact to both VMs in lockstep.
   _Output: end-to-end GitOps for a non-progressive rollout._
5. **Phase E - Canary phases + health check.** Add the phase loop, weight
   templating, and the `curl /healthz` health gate. _Output: progressive
   rollout works on the happy path._
6. **Phase F - Rollback.** `rollback.yml`, snapshot-before-deploy logic,
   the failing-binary demo path. _Output: rollback demo works._
7. **Phase G - Polish.** README with the topology diagram, demo recording,
   "future work" section (Prometheus-based error-rate signal, blue/green
   alternative, Slack notifications).

## Explicitly Out of Scope (v1) - and Why

Calling these out in the README signals that the omissions are deliberate,
not gaps.

- **Docker / containers** - defeats the purpose of a VM-deployment portfolio.
- **Prometheus / Grafana** - kept out for simplicity; noted as v2.
- **TLS on the LB** - not relevant to the GitOps story; would add cert-manager
  noise.
- **Multi-region / HA Jenkins** - controller is a single VM; this is a demo.
- **Secrets management (Vault, SSM)** - Ansible Vault is the natural
  v2 addition; v1 uses SSH keys provisioned by Terraform.
- **Database / stateful service** - the API is stateless on purpose so the
  canary story stays clean.
