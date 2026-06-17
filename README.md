# GitOps on VMs

A small, end-to-end GitOps system for **VM-based deployments**: progressive
canary rollouts and automatic rollback, driven entirely by commits to this
repo. No Kubernetes, no containers — a Go binary, `systemd`, nginx, Jenkins,
Ansible. The way a regulated ops shop (banks, telcos, vSphere shops) would
build this, but on AWS EC2 so it's reproducible.

This project is the deliberate counterpart to a Kubernetes + ArgoCD project.
Together they cover both delivery models a hiring team might care about.

```
                ┌─────────────────────┐
                │   gitops-jump       │   Mgmt subnet, public via EIP
                │   - Jenkins         │   (SSH tunnel for UI access)
                │   - Ansible         │
                └──────────┬──────────┘
                           │ SSH (Ansible)
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │ lb VM   │        │ app-vm1 │        │ app-vm2 │
   │ nginx   │◄──────►│ Go API  │        │ Go API  │
   │ (split) │ 8080   │ systemd │        │ systemd │
   └────┬────┘        └─────────┘        └─────────┘
        ▲                canary             stable
        │ HTTP from clients
```

## The Story In One Screen

**What it is.** A monorepo containing a Go RESTful API
([app/](app/)), Terraform to provision four EC2 VMs ([infra/](infra/)),
Ansible playbooks ([ansible/](ansible/)) that converge those VMs, and a
Jenkins pipeline ([jenkins/Jenkinsfile.deploy](jenkins/Jenkinsfile.deploy))
that watches the repo and reconciles state.

**The source of truth is [deploy/release.yaml](deploy/release.yaml).** It
declares the target version, the canary phase schedule (20% → 50% → 100%),
the health-check rule, and a `build_healthy` switch used to demonstrate
failure recovery. Editing this file *is* how you deploy.

**The flow on a successful release**: commit pushes to GitHub → Jenkins
polls every ~2 min, sees a change → builds the Go binary with the version
stamped in via `-ldflags` → deploys it to the canary VM (`app-vm1`) → shifts
nginx weight in phases, polling `/healthz` at each step → promotes stable
(`app-vm2`) once 100% passes → records the version as last-good.

**The flow on a broken release** (deliberately triggered by setting
`build_healthy: false`): canary deploy succeeds (the smoke test tolerates
500s when failure is expected) → Phase 1 shifts to 20% canary → health gate
sees consecutive 500s and trips → pipeline marks FAILURE → post-failure
recovery drains LB traffic from canary, runs
[ansible/rollback.yml](ansible/rollback.yml) to swap the canary symlink back
to last-good, restarts the service, restores 50/50 LB balance. The
user-facing state is fully restored to the last known good version — even
though Jenkins reports the build as failed.

The pipeline is observable from outside: every app response includes the
serving VM's `host` field, so a `watch -n 1 'curl ... | jq -c'` loop shows
traffic shifting in real time during the demo.

## How To Demo This

The full demo is six commands across three windows.

**Prereqs**: AWS account, an existing keypair named `ansible` (or rename in
`infra/`), the [docs/aws_plan.md](docs/aws_plan.md) prereqs done.

**One-time setup:**

```powershell
# Terminal 1 — provision
cd infra
terraform init -backend-config=backend.hcl
terraform apply

# Open Jenkins (via SSH tunnel; never exposed publicly)
ssh -i keys/gitops-vm.pem -L 8080:localhost:8080 ubuntu@$(terraform output -raw jump_public_ip)
# Browser: http://localhost:8080 — initial password under /var/lib/jenkins/secrets/initialAdminPassword
# Configure SSH credential 'fleet-key' and create the pipeline job from this repo.
# See jenkins/Jenkinsfile.deploy header comment for the click-by-click.

# Bootstrap fleet (one time per fresh fleet)
ssh -i keys/gitops-vm.pem ubuntu@$(terraform output -raw jump_public_ip)
cd Project_GitOps_VM/ansible && ansible-playbook bootstrap.yml
```

**The actual demo:**

```bash
# Terminal 2 (WSL) — watch the LB
watch -n 1 'curl -s "http://$(terraform -chdir=infra output -raw lb_public_ip)/" | jq -c'

# Terminal 3 — happy path
# Edit deploy/release.yaml: bump version, leave build_healthy: true
git add deploy/release.yaml app/VERSION && git commit -m "release: 0.3.0" && git push
# ~2 min: pipeline runs, canary loop, promote. watch shows traffic shift.

# Terminal 3 — failure path (the money shot)
# Edit deploy/release.yaml: bump version AGAIN, set build_healthy: false
git add deploy/release.yaml app/VERSION && git commit -m "demo: trigger rollback" && git push
# Pipeline trips during Phase 1, rolls canary back to prior good version,
# rebalances LB. watch shows: 50/50 -> canary visible -> drain -> rollback
# -> 50/50 again, both VMs on last-good.
```

## Architecture

Four EC2 VMs in one VPC, three subnets (DMZ / App / Mgmt) modelling the
canonical on-prem 3-zone network. Static private IPs, role-scoped Security
Groups, SSH only via the jump host. App subnet has no internet route at
all — belt + suspenders against accidental egress.

See [docs/aws_design.md](docs/aws_design.md) for the full design rationale
(why VMs, why no Packer in v1, why jump co-locates Jenkins+Ansible, the
on-prem-pattern checklist).

See [docs/aws_plan.md](docs/aws_plan.md) for the Terraform build order
(six phases, each adds one file, each independently verifiable).

## The Pipeline

Single Jenkinsfile ([jenkins/Jenkinsfile.deploy](jenkins/Jenkinsfile.deploy))
with these stages:

1. **Read release.yaml** — parse declared state into env vars.
2. **Build** — `go build` with `-ldflags "-X main.version=...
   [-X main.healthy=false]"`. The `healthy=false` flag is gated on
   `build_healthy: false` in release.yaml — that's the demo affordance for
   the failure path.
3. **Pre-deploy canary** — `ansible-playbook deploy.yml --limit app-vm1`.
   Versioned release dir + atomic symlink swap + systemd restart.
4. **Canary phase loop** — for each phase: `nginx.yml -e weight_canary=N`,
   then a `hold_seconds` health gate polling `/healthz` over SSH against
   the canary. Threshold consecutive failures trips abort.
5. **Promote: stable hosts** — same `deploy.yml`, `--limit app-vm2`, with
   `mark_last_good=true` so a successful promote records the rollback
   target.
6. **Reset LB to balanced** — `nginx.yml -e weight_canary=50`.

On failure (`post { failure }`):

1. **Drain LB** — `nginx.yml -e weight_canary=0`.
2. **Rollback canary** — `rollback.yml` reads `/opt/app/last-good`,
   swaps the symlink back, restarts.
3. **Restore balance** — `nginx.yml -e weight_canary=50` (only if rollback
   succeeded; otherwise leave canary drained for manual intervention).

See [docs/plan.md](docs/plan.md) for the original design intent (canary
phases, rollback signal, GitOps tenets) and the phase-by-phase build order.

## Deliberately Out Of Scope (v2 Roadmap)

Calling these out so the gaps read as deliberate, not as oversights.

- **Packer-baked golden AMI.** [packer/](packer/) is the placeholder.
  v1 uses stock Ubuntu 24.04 + cloud-init. Packer is the natural
  "golden template" pattern an on-prem team would use, deferred so the
  v1 demo ships.
- **Prometheus + Grafana.** Health gate uses curl in the pipeline. A v2
  with a 5xx-rate query as the gate is a one-screen swap.
- **TLS on the LB.** No cert-manager / ACM noise — the GitOps story is the
  point.
- **Separate `gitops-admin` vs `gitops-fleet` SSH keys.** Currently one
  shared key. Splitting it is a clean v2 — laptop has admin, jump generates
  fleet via `tls_private_key`.
- **Dynamic Ansible inventory.** Currently
  Terraform renders `inventory.ini` via `local_file`. Dynamic inventory
  (ec2.py-style) is a natural v2 when the fleet grows past 4 hosts.
- **Per-build release directories.** Re-deploying the same version
  overwrites the binary in place. Production-grade
  `/opt/app/releases/{version}/{build}/` is documented as a known
  limitation of v1 rollback in
  [ansible/rollback.yml](ansible/rollback.yml).
- **Webhook-driven Jenkins triggers.** Polls SCM every 2 min instead, so
  Jenkins stays behind the SSH-tunnel-only design.
- **Multi-AZ, HA Jenkins, multi-region.** Single AZ; multi-AZ would be
  theatre for a demo.
- **Secrets management (Ansible Vault, SSM).** SSH keys are provisioned by
  Terraform; the only "secret" in v1 is the fleet private key, gitignored.

## Why VMs (Not Kubernetes)

Most modern GitOps tutorials end with Kubernetes + ArgoCD. That's
solved. The interesting question is what GitOps looks like in environments
that **can't or won't** run Kubernetes — and there are a lot of those:
banks running vSphere, telcos on RHV, regulated ops teams whose change
control is shaped by ITIL more than DevOps.

This project demonstrates the same GitOps tenets — single source of truth,
declarative state, automated reconciliation, progressive delivery, automated
rollback — using a tool stack those environments actually run: Jenkins,
Ansible, nginx, `systemd`, SSH. The on-prem-pattern audit in
[docs/aws_design.md §2](docs/aws_design.md) makes that mapping explicit.

The application is a statically-linked Go binary by design. No Docker.
The artifact is the binary plus a `systemd` unit file — the canonical shape
for VM-native delivery.

## Repository Layout

```
.
├── app/                       # Go RESTful API source (gin)
│   ├── main.go                # entrypoint + graceful shutdown
│   ├── handlers.go            # GET / (with version + host) and /healthz
│   ├── handlers_test.go       # unit tests for both handlers
│   └── VERSION                # human-edited; baked into binary via ldflags
├── infra/                     # Terraform: VPC, 4 EC2s, SGs, EIPs, keypair
│   ├── 01_variables.tf        # admin_cidr (only real var; rest are locals)
│   ├── 03_local.tf            # region, project name, all CIDRs, static IPs
│   ├── 05_vpc.tf              # VPC + subnets + route tables
│   ├── 06_keypair.tf          # tls_private_key -> aws_key_pair + local .pem
│   ├── 07_ec2_jump.tf         # jump host + SG + EIP + cloud-init template
│   ├── 08_ec2_lb.tf           # nginx LB + SG + EIP
│   ├── 09_ec2_app.tf          # 2x app VMs + SG (egress restricted to VPC)
│   ├── 10_ansible_inventory.tf # renders ansible/inventory.ini from state
│   └── cloud-init/jump.yaml.tftpl # bootstraps Jenkins + Ansible + Go on jump
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini          # auto-generated by Terraform; do not edit
│   ├── bootstrap.yml          # one-time: create appuser, install nginx, etc
│   ├── deploy.yml             # release dir + symlink swap + smoke tests
│   ├── nginx.yml              # weight setter (weight_canary parameter)
│   ├── rollback.yml           # symlink back to last-good + restart
│   ├── templates/             # gitops-api.service.j2
│   └── roles/nginx/           # upstream.conf.j2 templating
├── deploy/
│   └── release.yaml           # source of truth — edit this to deploy
├── jenkins/
│   └── Jenkinsfile.deploy     # one pipeline: build + canary + rollback
├── packer/                    # placeholder for v2 golden-AMI build
└── docs/
    ├── plan.md                # overall technical design
    ├── aws_design.md          # AWS layer — what and why
    └── aws_plan.md            # AWS layer — phase-by-phase build order
```

## Cost

Approximately **$45/month** if left running 24/7 in `ca-central-1`:
~$17 for the `t3.small` jump host, ~$22 for three `t3.micro` (lb + 2× app),
~$10 for EBS. `terraform destroy` between demo cycles brings it to ~$0;
re-provisioning is ~3 minutes because the AMI lookup is just an API call
(no image build in v1).

## Status

All six implementation phases (A through F per
[docs/plan.md](docs/plan.md#L322)) are complete and verified end-to-end on
EC2. Phase G — this README — is the deliverable. A recorded demo (showing
the failure path with the `watch` loop) is planned as the final polish.
