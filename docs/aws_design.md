# AWS Infrastructure Plan

| Field         | Value                                          |
| ------------- | ---------------------------------------------- |
| Status        | Draft v1                                       |
| Author        | Simon Fong                                     |
| Last updated  | 2026-06-15                                     |
| Companion doc | [plan.md](plan.md) - overall technical design  |
| Scope         | AWS VPC + EC2 layer only (the `infra/` module) |

## 1. Purpose and Positioning

This document specifies the AWS layer that hosts the four VMs described in
[plan.md](plan.md). The goal is not "EC2s in a VPC" - it is to make the AWS
layout **look and behave like an on-prem VM environment**, because the whole
portfolio project is a deliberate counterpart to a separate Kubernetes +
ArgoCD project and targets reviewers from VM-shop industries (banks, telcos,
regulated ops teams).

Every design choice below is checked against the question: _would a vSphere /
RHV / bare-metal shop recognize this?_

## 2. On-Prem Patterns Being Modelled

The AWS layout mirrors the canonical 3-tier on-prem network:

| On-prem norm                                             | How this project models it                                 |
| -------------------------------------------------------- | ---------------------------------------------------------- |
| 3 trust zones (DMZ / App / Management) on separate VLANs | 3 subnets (DMZ / App / Mgmt) with role-scoped SGs          |
| App tier has no direct internet route                    | App subnet has no IGW route; SG egress restricted to VPC   |
| Bastion / jump host for all SSH access                   | `gitops-jump` in Mgmt subnet; fleet SSH is jump-only       |
| Static IPs documented in IPAM, hostnames in internal DNS | Static private IPs; `/etc/hosts` snippet pushed by Ansible |
| VMs ship from a golden template (vSphere / kickstart)    | Stock AL2023 AMI + Ansible bootstrap (see §7); Packer deferred to v2 |
| Control plane co-located on "utility servers"            | Jenkins + Ansible + jump duties on a single Mgmt-zone VM   |
| Agent-based monitoring on a management VLAN host         | `gitops-mon` runs Prometheus + Grafana in the Mgmt subnet  |
| Change control via tickets and approvals                 | Replaced by Git commits as the change record (the point)   |

Patterns intentionally **not** modelled in v1, called out so reviewers see the
omissions as deliberate: internal patch mirror (Spacewalk/Pulp), SSH cert
authority + session recording (Vault SSH / Teleport / tlog), backup target
(Veeam/Restic). All listed as v2 in the README.

## 3. Region and AZ

| Item   | Value           | Reason                                           |
| ------ | --------------- | ------------------------------------------------ |
| Region | `ca-central-1`  | Locked in project decisions; closest to author   |
| AZ     | `ca-central-1a` | Single AZ - multi-AZ would be theatre for a demo |

## 4. VPC and Subnets

Single VPC, three subnets, two route tables.

```
VPC  10.0.0.0/16   (ca-central-1a)

┌─ DMZ subnet           10.0.10.0/24   (public,  IGW route)
│   └── gitops-lb       10.0.10.20     nginx - only internet-facing host
│
├─ App subnet           10.0.20.0/24   (private, NO IGW route)
│   ├── gitops-app-vm1  10.0.20.11     canary
│   └── gitops-app-vm2  10.0.20.12     stable
│
└─ Mgmt subnet          10.0.99.0/24   (public, locked to admin CIDR)
    └── gitops-jump     10.0.99.10     Jenkins + Ansible + jump host
```

Route tables:

| Route table  | Attached to       | Routes                                 |
| ------------ | ----------------- | -------------------------------------- |
| `rt-public`  | DMZ, Mgmt subnets | `10.0.0.0/16` local; `0.0.0.0/0` → IGW |
| `rt-private` | App subnet        | `10.0.0.0/16` local (only)             |

The App subnet having literally no path to the internet is the on-prem
signal - app servers in a real DC reach the outside world through an explicit
proxy or an internal mirror, or not at all.

CIDR convention: `.10` = DMZ, `.20` = App, `.99` = Mgmt. The `.99` for the
management network is an on-prem habit worth borrowing.

## 5. EC2 Instances

| Role       | Name tag         | Internal DNS | Type       | Subnet | Private IP | Public IP |
| ---------- | ---------------- | ------------ | ---------- | ------ | ---------- | --------- |
| Controller | `gitops-jump`    | `jump`       | `t3.small` | Mgmt   | 10.0.99.10 | EIP       |
| LB         | `gitops-lb`      | `lb`         | `t3.micro` | DMZ    | 10.0.10.20 | EIP       |
| App canary | `gitops-app-vm1` | `app-vm1`    | `t3.micro` | App    | 10.0.20.11 | none      |
| App stable | `gitops-app-vm2` | `app-vm2`    | `t3.micro` | App    | 10.0.20.12 | none      |
| Monitoring | `gitops-mon`     | `mon`        | `t3.small` | Mgmt   | 10.0.90.20 | none      |

- **AMI**: latest AL2023, resolved at apply time via `data "aws_ami"` filter
  (owner Amazon, name pattern `al2023-ami-2023.*-x86_64`). See §7.
- **Static private IPs** set explicitly on every `aws_instance` so the
  Ansible inventory and `/etc/hosts` snippet stay stable across
  `terraform apply` runs.
- **EIPs on jump and LB only.** Jenkins URL and the public service entry
  point need stable addresses across reboots. App VMs have no public address
  at all.
- **`t3.small` for jump** is the realistic floor - `t3.micro` (1 GB RAM)
  will OOM during Jenkins startup or a Go build. `t3.medium` if you want
  headroom.

### 5.1 Why Jenkins co-locates on `gitops-jump`

Plan locks Jenkins to the controller VM, and the on-prem analog backs it up:
small shops put Jenkins, Ansible, and the SSH bastion on the same
"utility server" on the management VLAN. A separate Jenkins VM would add
cost and a fifth SG for no portfolio gain. The natural scale-out story -
Jenkins controller + dedicated build agents - is called out as future work
in the README.

Reaching Jenkins from the laptop is via SSH tunnel
(`ssh -L 8080:localhost:8080 ec2-user@<jump-eip>`), not by exposing port 8080. Mirrors how an on-prem team would reach internal Jenkins via VPN, and
costs one extra shell command per demo.

## 6. Security Groups

Role-scoped, not per-VM, so the Terraform stays readable and the diagram
matches reality.

| SG        | Attached to      | Ingress                                                                                                  | Egress             |
| --------- | ---------------- | -------------------------------------------------------------------------------------------------------- | ------------------ |
| `sg-jump` | jump             | 22 from `var.admin_cidr`                                                                                 | all                |
| `sg-lb`   | lb               | 80 from `0.0.0.0/0`; 22 from `sg-jump`                                                                   | all                |
| `sg-app`  | app-vm1, app-vm2 | 8080 from `sg-lb`; 8080 from `sg-jump` (healthz curl); 8080 from `sg-mon` (scrape); 22 from `sg-jump`    | `10.0.0.0/16` only |
| `sg-mon`  | mon              | 22 from `sg-jump`; 9090 from `sg-jump` (Prometheus tunnel); 3000 from `sg-jump` (Grafana tunnel)         | all                |

Points worth flagging because they're easy to miss:

- **App SG egress restricted to the VPC CIDR.** Belt + suspenders alongside
  the missing IGW route. App VMs cannot reach the internet even if a route
  existed.
- **SSH only from jump.** Your laptop SSHes to `jump`; jump SSHes to
  everything else. Classic bastion pattern.
- **Health-check path requires app-from-jump on 8080.** The deploy pipeline
  curls `app-vm1:8080/healthz` from the controller, so port 8080 from
  `sg-jump` to `sg-app` is required - not just 8080 from `sg-lb`.
- **Scrape path requires app-from-mon on 8080.** Prometheus on `gitops-mon`
  scrapes `app-vm{1,2}:8080/metrics`, so port 8080 from `sg-mon` to `sg-app`
  is required. Mon itself is only reachable via SSH tunnel through jump
  (ports 9090 / 3000), same posture as Jenkins.
- **No Jenkins SG ingress for 8080.** Jenkins is reached only via SSH
  tunnel, so port 8080 stays bound to localhost on the jump host.

## 7. Bootstrap - Stock AL2023 AMI

VMs boot from the latest official Amazon Linux 2023 AMI, resolved at
`terraform apply` time via a `data "aws_ami"` lookup. No image baking.

**Why not Packer.** Packer was considered and rejected for v1. The honest
audit: stock AL2023 already ships with everything this project needs at
first boot - `python3` (for Ansible), `cloud-init` (for `user_data`),
`chronyd` (time sync), sshd with sane defaults (no root login, no password
auth). The only thing missing is the `appuser` account, and Ansible
creates it in one task. A pre-baked AMI would have added a tool and a
~10-minute build step for one task's worth of savings.

Crucially, the app itself is a **statically-linked Go binary** - there is
nothing to `dnf install` on the app VMs at any point. Ansible converges
everything over SSH from the jump host. App VMs never need internet.

Packer is listed in README v2 future work for the *narrative* reason:
"ship from a golden template" is a recognizable on-prem pattern worth
demonstrating once the v1 demo is working.

`user_data` on each instance does the bare minimum:

1. Set hostname to the value in the name tag.
2. Write the `/etc/hosts` snippet for the four-host fleet.
3. Drop the jump's SSH public key into `appuser`'s `authorized_keys`
   (app + LB VMs only; not jump itself).

Everything else - creating `appuser`, installing the app binary, writing
systemd units, templating nginx config - is Ansible's job, run from jump
over SSH.

No application config, no package installs. The line between "image" and
"convergence" is exactly where an on-prem team would draw it.

## 8. DNS - `/etc/hosts` as Internal DNS

No Route 53 private zone - overkill for four hosts. Terraform renders an
`/etc/hosts` snippet via `local_file`, and the Ansible bootstrap role
pushes it to every VM:

```
10.0.99.10  jump
10.0.10.20  lb
10.0.20.11  app-vm1
10.0.20.12  app-vm2
```

The Ansible inventory then reads hostnames, not IPs:

```ini
[lb]
lb

[app_canary]
app-vm1

[app_stable]
app-vm2
```

This mirrors how an on-prem shop uses internal BIND or Windows DNS, and
removes the "I changed an IP, Ansible broke" papercut.

## 9. Key Management

Two SSH keypairs, both Ed25519:

| Keypair        | Generated                        | Used for                      | Stored where                                                  |
| -------------- | -------------------------------- | ----------------------------- | ------------------------------------------------------------- |
| `gitops-admin` | Locally on laptop                | Laptop → `jump`               | `keys/gitops-admin{,.pub}`, gitignored                        |
| `gitops-fleet` | By Terraform (`tls_private_key`) | `jump` → lb, app-vm1, app-vm2 | Private half written to `jump` user_data; never leaves the VM |

The `gitops-admin` public half is registered as `aws_key_pair` and attached
to the jump instance. The `gitops-fleet` public half is injected into the
`user_data` of the other three VMs as `appuser`'s authorized key. Result:
jump can SSH to the fleet from first boot, no manual key copying.

## 10. Terraform Module Layout

```
infra/
├── main.tf              provider, VPC, IGW, subnets, route tables
├── security.tf          the 3 SGs
├── instances.tf         4 aws_instance + 2 EIPs + 2 key_pair + tls_private_key
├── ami.tf               data source for latest AL2023 AMI
├── inventory.tf         local_file rendering ansible/inventory.ini + /etc/hosts snippet
├── outputs.tf           public IPs, private IPs, ssh + tunnel command hints
├── variables.tf         admin_cidr, region, instance sizes, key paths
└── terraform.tfvars.example
```

`inventory.tf` writing `ansible/inventory.ini` directly closes the
Terraform → Ansible loop without dynamic inventory (deferred to v2 per the
locked decisions).

## 11. Cost Estimate

Rough monthly cost if left running 24/7 in `ca-central-1` (on-demand pricing,
approximate):

| Item                         | Quantity | Approx. monthly |
| ---------------------------- | -------- | --------------- |
| `t3.small` (jump)            | 1        | ~$17            |
| `t3.micro` (lb, app x2)      | 3        | ~$22            |
| `t3.small` (mon)             | 1        | ~$17            |
| EIPs (attached, no charge)   | 2        | $0              |
| EBS gp3 30 GB per VM         | 5        | ~$13            |
| Data transfer (demo traffic) | minimal  | <$1             |
| **Total**                    |          | **~$70/mo**     |

Recommendation: `terraform destroy` between demo sessions. Re-provisioning
takes minutes because AMI lookup is just an API call, no image build.

## 12. Open Questions

Settle before drafting Terraform:

1. **`var.admin_cidr`** - your home IP/32 only, or a wider range?
2. **Jenkins access** - confirm SSH tunnel only (recommended), or also
   open 8080 on `sg-jump` to `var.admin_cidr`?

## 13. Out of Scope for v1

Called out so the gaps read as deliberate, not as oversights:

- Multi-AZ, multi-region, HA Jenkins
- TLS on the LB (no cert-manager / ACM noise; the GitOps story is the point)
- VPC Flow Logs, CloudTrail, GuardDuty
- Internal patch mirror (app VMs install nothing at runtime; the Go binary is static)
- Packer-baked golden AMI (the on-prem "golden template" pattern; deferred to v2)
- `node_exporter` on app VMs (CPU/mem panels would be cosmetic; the app's own `/metrics` already tells the canary story)
- SSH cert authority / session recording on the jump host
- Backup target on the Mgmt subnet
- Secrets management (Ansible Vault is the natural v2 addition; v1 uses
  SSH keys provisioned by Terraform)
