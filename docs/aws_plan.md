# AWS Infrastructure Plan - Implementation Steps

| Field         | Value                                                |
| ------------- | ---------------------------------------------------- |
| Status        | Draft v2                                             |
| Author        | Simon Fong                                           |
| Last updated  | 2026-06-16                                           |
| Companion doc | [aws_design.md](aws_design.md) - what we're building |
| Scope         | Build order for the `infra/` Terraform module        |

This document is the **how**. [aws_design.md](aws_design.md) is the
**what and why** - read it first.

**Build philosophy.** Each phase from 3 onward lands one more VM that you
can SSH into, with its SG and instance in the same file. If a phase
breaks, you fix the one file and re-apply - no jumping back to an earlier
phase. Inventory rendering and Ansible bootstrap are out of scope for
this doc; they live in [plan.md](plan.md) under the Ansible milestones.

## Prerequisites

Install once, locally:

| Tool       | Min version | Purpose                             |
| ---------- | ----------- | ----------------------------------- |
| Terraform  | 1.7         | Provisioning                        |
| AWS CLI v2 | 2.15        | Credentials, state bucket bootstrap |
| OpenSSH    | any         | SSH to jump, tunnel to Jenkins      |

AWS account setup:

- IAM user (or SSO role) with admin on `ca-central-1`.
- `aws configure --profile gitops-vm` so the named profile exists.
- Confirm: `aws --profile gitops-vm sts get-caller-identity` returns your
  account.

SSH keypair: this project uses an **existing** AWS keypair named
`ansible`. Confirm it exists and you have the private half locally:

```powershell
aws --profile gitops-vm ec2 describe-key-pairs `
  --key-names ansible --query "KeyPairs[].KeyName"
ls ~/.ssh/ansible    # or wherever the private key lives
```

Local repo prep (one-time):

```powershell
echo "keys/"        >> .gitignore
echo "*.tfstate*"   >> .gitignore
echo ".terraform/"  >> .gitignore
echo "backend.hcl"  >> .gitignore
echo "*.tfvars"     >> .gitignore
echo "!*.example"   >> .gitignore
echo "tfplan"       >> .gitignore
```

## File naming convention

`infra/` uses a numeric prefix so `ls` sorts in read-order:

```
01_variables.tf      inputs (admin_cidr only)
02_providers.tf      terraform + provider config + backend
03_local.tf          locals (region, project name, all CIDRs, static IPs)
04_output.tf         outputs
05_vpc.tf            Phase 2 - network (VPC, IGW, subnets, RTs)
06_ec2_jump.tf       Phase 3 - jump host  (AMI + keypair data + sg + instance + EIP)
07_ec2_lb.tf         Phase 4 - load balancer (sg + instance + EIP)
08_ec2_app.tf        Phase 5 - app VMs (sg + 2× instance)
```

One file per role from Phase 2 onward. Each EC2 file contains the SG, the
instance, and (if applicable) the EIP for that role.

**Locals vs variables.** Almost everything is a `local` in [03_local.tf](../infra/03_local.tf):
region, project name, all subnet CIDRs, all static private IPs. The only
input variable is `admin_cidr` because it's environment-specific (your
workstation IP) and must not be committed.

---

## Phase 1 - Bootstrap

Set up the Terraform plumbing: remote state backend, provider config,
input variables. Ends with `terraform plan` printing a clean no-op
against an empty configuration.

### Why remote state

Terraform state holds secrets (private IPs, sensitive outputs) and must
not live in the repo. Standard AWS pattern: S3 for the state object,
DynamoDB for the lock. Created **outside** the Terraform module
(chicken-and-egg: the module cannot manage the bucket that holds its own
state).

### Steps

**1. Create the state bucket and lock table** (run once, ever):

```powershell
$REGION  = "ca-central-1"
$BUCKET  = "simonangelfong-terraform-backend"
$TABLE   = "gitops-vm-tflock"
$PROFILE = "gitops-vm"

aws --profile $PROFILE s3api create-bucket `
  --bucket $BUCKET --region $REGION `
  --create-bucket-configuration LocationConstraint=$REGION

aws --profile $PROFILE s3api put-bucket-versioning `
  --bucket $BUCKET --versioning-configuration Status=Enabled

aws --profile $PROFILE s3api put-public-access-block `
  --bucket $BUCKET --public-access-block-configuration `
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws --profile $PROFILE dynamodb create-table `
  --table-name $TABLE --region $REGION `
  --attribute-definitions AttributeName=LockID,AttributeType=S `
  --key-schema AttributeName=LockID,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST
```

**2. Create the Terraform skeleton** under `infra/`:

| File                       | Purpose                                                                                          |
| -------------------------- | ------------------------------------------------------------------------------------------------ |
| `01_variables.tf`          | `admin_cidr` only (workstation IP, environment-specific)                                         |
| `02_providers.tf`          | `terraform` block (versions + S3 backend), `provider "aws"` (reads `local.aws_region` + profile) |
| `03_local.tf`              | `aws_region`, `project_name`, all subnet CIDRs, all static private IPs                           |
| `04_output.tf`             | outputs (filled in by later phases)                                                              |
| `backend.hcl`              | bucket/region/profile values for `terraform init` (gitignored)                                   |
| `terraform.tfvars`         | `admin_cidr` value (gitignored; starts as placeholder)                                           |
| `terraform.tfvars.example` | committed template                                                                               |

**3. Initialize and verify**:

```powershell
cd infra
terraform init -backend-config=backend.hcl
terraform validate
terraform plan       # must print "No changes."
```

### Verification

```powershell
aws --profile gitops-vm s3 ls s3://simonangelfong-terraform-backend/
aws --profile gitops-vm dynamodb describe-table `
  --table-name gitops-vm-tflock --query "Table.TableStatus"
```

State object lives at `s3://simonangelfong-terraform-backend/gitops-vm/infra/terraform.tfstate`
after the first apply.

---

## Phase 2 - Network

VPC, IGW, three subnets (DMZ, App, Mgmt), two route tables (public,
private). No instances, no SGs yet.

### File

`infra/05_vpc.tf`

Resources (see [aws_design.md §4](aws_design.md) for the spec):

- `aws_vpc.main` - `10.0.0.0/16`, DNS hostnames + support on
- `aws_internet_gateway.main`
- `aws_subnet.dmz` - `10.0.10.0/24`, `map_public_ip_on_launch = true`
- `aws_subnet.app` - `10.0.20.0/24`, `map_public_ip_on_launch = false`
- `aws_subnet.mgmt` - `10.0.90.0/24`, `map_public_ip_on_launch = true`
- `aws_route_table.public` - `0.0.0.0/0` → IGW
- `aws_route_table.private` - local only, no default route
- Three `aws_route_table_association` (DMZ + Mgmt → public; App → private)

### Steps

```powershell
terraform plan -out tfplan
terraform apply tfplan
```

### Verification

```powershell
aws --profile gitops-vm ec2 describe-subnets `
  --filters "Name=tag:Project,Values=gitops-vm" `
  --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,MapPublicIpOnLaunch]" `
  --output table

# Critical: App subnet has NO 0.0.0.0/0 route
aws --profile gitops-vm ec2 describe-route-tables `
  --filters "Name=tag:Name,Values=gitops-vm-rt-private" `
  --query "RouteTables[].Routes" --output table
# Should show only the 10.0.0.0/16 local route, no igw-*
```

Cost: $0/mo. VPC, subnets, RTs, IGW are all free.

---

## Phase 3 - Jump Host

First VM. Lives in the Mgmt subnet, has an EIP, accepts SSH from
`var.admin_cidr` only. This is the only VM you SSH to from your laptop;
all subsequent phases reach their VMs _through_ it.

### Files

- `infra/03_local.tf` - adds `ec2_jump_cidr` to the locals block
- `infra/06_ec2_jump.tf` - AMI + keypair data sources + `sg-jump` + `aws_instance.jump` + `aws_eip.jump`

Resources:

```hcl
# In 03_local.tf
locals {
  # ...existing CIDRs...
  ec2_jump_cidr = "10.0.90.10"
}

# In 06_ec2_jump.tf
data "aws_ami" "al2023"       { ... }   # AL2023 lookup
data "aws_key_pair" "ansible" { key_name = "ansible" }

resource "aws_security_group" "jump" { ... }
resource "aws_vpc_security_group_ingress_rule" "jump_ssh_from_admin" { ... }
resource "aws_vpc_security_group_egress_rule"  "jump_egress_all"     { ... }

resource "aws_instance" "jump" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.mgmt.id
  private_ip             = local.ec2_jump_cidr
  vpc_security_group_ids = [aws_security_group.jump.id]
  key_name               = data.aws_key_pair.ansible.key_name
  tags                   = { Name = "${local.project_name}-jump", Role = "jump" }
}

resource "aws_eip" "jump" {
  instance = aws_instance.jump.id
  domain   = "vpc"
  tags     = { Name = "${local.project_name}-jump-eip" }
}
```

Data sources live in the file that first needs them (AMI + keypair are used
by every EC2 phase, but they're declared in `06_ec2_jump.tf` since jump is
the first VM). Later phases reference them by the same `data.aws_ami.al2023`
/ `data.aws_key_pair.ansible` addresses.

### Prerequisite

Set `admin_cidr` in `infra/terraform.tfvars` to your workstation IP:

```powershell
(Invoke-WebRequest -Uri https://checkip.amazonaws.com -UseBasicParsing).Content.Trim()
# Then edit infra/terraform.tfvars:
# admin_cidr = "<that-ip>/32"
```

### Steps

```powershell
terraform plan -out tfplan
terraform apply tfplan
```

### Verification

```powershell
terraform output jump_public_ip   # add this output in 04_output.tf

ssh -i ~/.ssh/ansible ec2-user@<jump-public-ip> 'hostname && uname -a'
```

If SSH hangs: your public IP changed (re-run `checkip.amazonaws.com`,
update `admin_cidr`, re-apply). If "permission denied": confirm the
`ansible` keypair private half is at `~/.ssh/ansible` and `chmod 400`.

Cost from this phase on: ~$17/mo for the `t3.small` + ~$3/mo for the EBS
volume. EIP free while attached.

---

## Phase 4 - Load Balancer

Public-facing nginx VM in the DMZ subnet. Reached on port 80 from the
internet; SSH only from jump.

### Files

- `infra/03_local.tf` - adds `ec2_lb_cidr = "10.0.10.20"` to the locals block
- `infra/07_ec2_lb.tf` - `sg-lb` + `aws_instance.lb` + `aws_eip.lb`

Resources:

```hcl
# In 03_local.tf
locals {
  # ...existing...
  ec2_lb_cidr = "10.0.10.20"
}

# In 07_ec2_lb.tf
resource "aws_security_group" "lb" { ... }
resource "aws_vpc_security_group_ingress_rule" "lb_http_from_world" { ... }
resource "aws_vpc_security_group_ingress_rule" "lb_ssh_from_jump"   { ... }
resource "aws_vpc_security_group_egress_rule"  "lb_egress_all"      { ... }

resource "aws_instance" "lb" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.dmz.id
  private_ip             = local.ec2_lb_cidr
  vpc_security_group_ids = [aws_security_group.lb.id]
  key_name               = data.aws_key_pair.ansible.key_name
  tags                   = { Name = "${local.project_name}-lb", Role = "lb" }
}

resource "aws_eip" "lb" {
  instance = aws_instance.lb.id
  domain   = "vpc"
  tags     = { Name = "${local.project_name}-lb-eip" }
}
```

The `lb_ssh_from_jump` rule uses `referenced_security_group_id =
aws_security_group.jump.id` - SG-to-SG reference, not a CIDR. This is the
on-prem-style bastion pattern: SSH access flows by *role* (jump → lb), not
by IP.

### Steps

```powershell
terraform plan -out tfplan
terraform apply tfplan
```

### Verification

```powershell
terraform output lb_public_ip

# From your laptop: port 80 reachable (will fail-to-connect until Ansible installs nginx, but the SG is open)
nc -zv <lb-public-ip> 80

# From jump: SSH to lb works
ssh -i ~/.ssh/ansible ec2-user@<jump-public-ip> `
  "ssh -o StrictHostKeyChecking=accept-new ec2-user@10.0.10.20 hostname"
```

Wait - jump can't SSH to lb yet because jump doesn't have the `ansible`
private key in `~/.ssh/`. That's an **Ansible-layer concern** (handled by
the bootstrap playbook in [plan.md](plan.md) Phase A). For now, verify
network reachability only:

```powershell
ssh -i ~/.ssh/ansible ec2-user@<jump-public-ip> `
  "nc -zv 10.0.10.20 22"
# "Connection to 10.0.10.20 port 22 [tcp/ssh] succeeded!"
```

Cost: +~$8/mo (`t3.micro` + EBS).

---

## Phase 5 - App VMs

Two app VMs in the App subnet. **No EIPs, no public IPs** - reachable
only from inside the VPC. App subnet has no route to the internet, so
these VMs cannot reach the outside world even outbound.

### Files

- `infra/03_local.tf` - adds `ec2_app_vm1_cidr = "10.0.20.11"` and `ec2_app_vm2_cidr = "10.0.20.12"`
- `infra/08_ec2_app.tf` - `sg-app` + `aws_instance.app_vm1` + `aws_instance.app_vm2`

Resources:

```hcl
# In 03_local.tf
locals {
  # ...existing...
  # App subnet
  subnet_app_cidr  = "10.0.20.0/24"
  ec2_app_vm1_cidr = "10.0.20.11"
  ec2_app_vm2_cidr = "10.0.20.12"
}

# In 08_ec2_app.tf
resource "aws_security_group" "app" { ... }
resource "aws_vpc_security_group_ingress_rule" "app_8080_from_lb"   { ... }  # SG-to-SG: sg-lb
resource "aws_vpc_security_group_ingress_rule" "app_8080_from_jump" { ... }  # SG-to-SG: sg-jump (healthz curl)
resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_jump"  { ... }  # SG-to-SG: sg-jump
resource "aws_vpc_security_group_egress_rule"  "app_egress_vpc_only" {
  cidr_ipv4   = aws_vpc.main.cidr_block   # 10.0.0.0/16, NOT 0.0.0.0/0
  ip_protocol = "-1"
}

resource "aws_instance" "app_vm1" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.app.id
  private_ip             = local.ec2_app_vm1_cidr
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = data.aws_key_pair.ansible.key_name
  tags                   = { Name = "${local.project_name}-app-vm1", Role = "canary" }
}

resource "aws_instance" "app_vm2" {
  # identical except private_ip = local.ec2_app_vm2_cidr, Name = ${local.project_name}-app-vm2, Role = stable
}
```

Two ingress rules to `sg-app` on port 8080 (one from `sg-lb`, one from
`sg-jump`) look redundant but aren't - `sg-lb` carries production traffic
while `sg-jump` is the source for the deploy pipeline's `curl
app-vm1:8080/healthz` check. Splitting them keeps the *intent* of each
rule visible in the SG.

### Steps

```powershell
terraform plan -out tfplan
terraform apply tfplan
```

### Verification

```powershell
# From jump: confirm app VMs are reachable on SSH and 8080
ssh -i ~/.ssh/ansible ec2-user@<jump-public-ip> `
  "nc -zv 10.0.20.11 22 && nc -zv 10.0.20.12 22"

# From jump: confirm app-vm1 has NO internet
ssh -i ~/.ssh/ansible ec2-user@<jump-public-ip> `
  "nc -zv 10.0.20.11 8080"   # SG allows; service not yet running → connection refused
```

The "no internet" check needs SSH all the way to app-vm1, which depends
on jump having the keypair - Ansible-layer. Defer to Phase 6 smoke test
(or to the Ansible bootstrap milestone).

Cost: +~$16/mo (2× `t3.micro` + EBS).

---

## Phase 6 - Outputs, Smoke Test, Teardown

Finalize outputs (so the demo runbook is copy-pasteable) and verify the
whole AWS layer end-to-end. After this, control passes to the Ansible
layer in [plan.md](plan.md).

### Outputs (`04_output.tf`)

```hcl
output "jump_public_ip" { value = aws_eip.jump.public_ip }
output "lb_public_ip"   { value = aws_eip.lb.public_ip }
output "app_vm1_ip"     { value = aws_instance.app_vm1.private_ip }
output "app_vm2_ip"     { value = aws_instance.app_vm2.private_ip }

output "ssh_jump" {
  value = "ssh -i ~/.ssh/ansible ec2-user@${aws_eip.jump.public_ip}"
}

output "jenkins_tunnel" {
  value = "ssh -i ~/.ssh/ansible -L 8080:localhost:8080 ec2-user@${aws_eip.jump.public_ip}"
}
```

### Smoke test

```powershell
terraform output
$JUMP = terraform output -raw jump_public_ip

# 1. Reach jump
ssh -i ~/.ssh/ansible ec2-user@$JUMP "hostname && uname -a"

# 2. From jump, port-reach all three other VMs
ssh -i ~/.ssh/ansible ec2-user@$JUMP @"
  for ip in 10.0.10.20 10.0.20.11 10.0.20.12; do
    echo -n "$ip:22 "
    nc -zv $ip 22 2>&1 | grep -o 'succeeded\|refused\|timed out'
  done
"@
```

If all three say "succeeded" the AWS layer is done. Ansible takes over
from here ([plan.md](plan.md) Phase A: bootstrap playbook, including
installing the `ansible` private key on jump so it can SSH onward).

### Teardown

`terraform destroy` removes everything in the module. **Does not remove**
the S3 state bucket or DynamoDB lock table from Phase 1 - keep these
between demo cycles so re-provisioning is fast.

To fully wipe afterward:

```powershell
aws --profile gitops-vm s3 rm s3://simonangelfong-terraform-backend --recursive
aws --profile gitops-vm s3api delete-bucket --bucket simonangelfong-terraform-backend
aws --profile gitops-vm dynamodb delete-table --table-name gitops-vm-tflock
```

---

## Phase Summary

| Phase | What                          | Files                                                  | Cost added |
| ----- | ----------------------------- | ------------------------------------------------------ | ---------- |
| 1     | Bootstrap state + TF skeleton | 01–04, `backend.hcl`, `*.tfvars`                       | $0         |
| 2     | Network                       | `05_vpc.tf`                                            | $0         |
| 3     | Jump host                     | `06_ec2_jump.tf` (AMI + keypair data here too)         | ~$20/mo    |
| 4     | LB                            | `07_ec2_lb.tf` (+ `ec2_lb_cidr` in `03_local.tf`)      | +~$8/mo    |
| 5     | App VMs                       | `08_ec2_app.tf` (+ `ec2_app_vm{1,2}_cidr` in `03_local.tf`) | +~$16/mo   |
| 6     | Outputs + smoke test          | `04_output.tf`                                         | $0         |

Total: ~$45/mo if left running. `terraform destroy` between demo
sessions keeps it near $0.

After Phase 6, the AWS layer is complete. Next milestone is the Ansible
bootstrap playbook (covered in [plan.md](plan.md), Phase A) - including
inventory rendering, `/etc/hosts` setup, and getting the `ansible`
keypair onto jump so it can reach the fleet.
