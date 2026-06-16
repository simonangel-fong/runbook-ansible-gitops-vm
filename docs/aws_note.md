# Terraform

```sh
# confirm AWS profile works and reaches your account
aws --profile gitops-vm sts get-caller-identity

# Confirm the state bucket exists (from Phase 0)
aws --profile gitops-vm s3 ls s3://simonangelfong-terraform-backend

cd infra
terraform init -backend-config=backend.hcl

# Validate syntax
terraform validate
# terraform plan -out=tfplan
# terraform show -json tfplan > plan.json

terraform apply tfplan
terraform apply -auto-approve

```

---

## Connect jump

```sh
terraform output -raw ssh_jump
# ssh -i keys/gitops-vm.pem ec2-user@16.52.229.58

ssh -i keys/gitops-vm.pem ec2-user@16.52.229.58
```

## Login jenkins

```sh
# Confirm jenkins
systemctl status jenkins      # active (running)

# forward jenkins UI
terraform output -raw jenkins_tunnel
# ssh -i keys/gitops-vm.pem -L 8080:localhost:8080 ec2-user@16.52.229.58

# init pwd
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

## Confirm Ansible

```sh
cd ansible
ansible all -m ping -o
```
