# GitOps VM: Provision Infrastructure

[Back](../README.md)

- [GitOps VM: Provision Infrastructure](#gitops-vm-provision-infrastructure)
  - [Terraform Apply](#terraform-apply)
  - [Connect jump](#connect-jump)

---

## Terraform Apply

```sh
# confirm AWS profile works and reaches account
aws --profile gitops-vm sts get-caller-identity

# Confirm the state bucket exists (from Phase 0)
aws --profile gitops-vm s3 ls s3://simonangelfong-terraform-backend

terraform -chdir=infra/ init -backend-config=backend.hcl

# Validate syntax
terraform -chdir=infra/ validate
# terraform plan -out=tfplan
# terraform show -json tfplan > plan.json
# terraform -chdir=infra/ apply tfplan

terraform -chdir=infra/ apply -auto-approve
terraform -chdir=infra/ destroy -auto-approve
```

---

## Connect jump

```sh
# get the updated ssh cmd
terraform -chdir=infra/ output -raw ssh_jump
# ssh -i infra/keys/gitops-vm.pem ubuntu@16.52.14.216

ssh -i infra/keys/gitops-vm.pem ubuntu@16.52.14.216

# Confirm Ansible
cd ~/runbook-ansible-gitops-vm/ansible
ansible all -m ping -o
# jump | SUCCESS => {"changed": false,"ping": "pong"}
# lb | SUCCESS => {"changed": false,"ping": "pong"}
# app-vm1 | SUCCESS => {"changed": false,"ping": "pong"}
# mon | SUCCESS => {"changed": false,"ping": "pong"}
# app-vm2 | SUCCESS => {"changed": false,"ping": "pong"}
```

---
