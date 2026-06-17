# Terraform

```sh
# confirm AWS profile works and reaches your account
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
terraform -chdir=infra/ output -raw ssh_jump
# ssh -i infra/keys/gitops-vm.pem ec2-user@16.52.229.58

sssh -i infra/keys/gitops-vm.pem ec2-user@16.52.229.58
```

## Login jenkins

```sh
# Confirm jenkins
systemctl status jenkins      # active (running)

# forward jenkins UI
terraform -chdir=infra/ output -raw jenkins_tunnel
# ssh -i infra/keys/gitops-vm.pem -L 8080:localhost:8080 ubuntu@16.52.182.125

ssh -i infra/keys/gitops-vm.pem -L 8080:localhost:8080 ubuntu@16.52.182.125

# init pwd
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

## Confirm Ansible

```sh
cd ansible
ansible all -m ping -o
```

---

## Build Go

```sh
cd app
VERSION=$(cat VERSION)
go build -ldflags "-X main.version=$VERSION" -o /tmp/gitops-api .
ls -la /tmp/gitops-api
# -rwxrwxr-x 1 ubuntu ubuntu 20719788 Jun 16 22:00 /tmp/gitops-api

cd ../ansible
ansible-playbook deploy.yml \
  -e binary_src=/tmp/gitops-api \
  -e app_version=$VERSION
```

- deploy

```sh
ansible-playbook bootstrap.yml

# PLAY [A2 — Connectivity check (every fleet host)] **************************************************************************

# TASK [Ping] ****************************************************************************************************************
# ok: [lb]
# ok: [app-vm1]
# ok: [app-vm2]

# PLAY [A3a — LB base setup] *************************************************************************************************

# TASK [Gathering Facts] *****************************************************************************************************
# ok: [lb]

# TASK [Install nginx] *******************************************************************************************************
# changed: [lb]

# TASK [Enable nginx (do not start — no upstream config yet)] ****************************************************************
# ok: [lb]

# PLAY [A3b — App VM base setup] *********************************************************************************************

# TASK [Gathering Facts] *****************************************************************************************************
# ok: [app-vm1]
# ok: [app-vm2]

# TASK [Create appuser] ******************************************************************************************************
# changed: [app-vm1]
# changed: [app-vm2]

# TASK [Create /opt/app layout] **********************************************************************************************
# changed: [app-vm1] => (item=/opt/app)
# changed: [app-vm2] => (item=/opt/app)
# changed: [app-vm2] => (item=/opt/app/releases)
# changed: [app-vm1] => (item=/opt/app/releases)

# PLAY RECAP *****************************************************************************************************************
# app-vm1                    : ok=4    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
# app-vm2                    : ok=4    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
# lb                         : ok=4    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0


VERSION=$(cat ../app/VERSION)
ansible-playbook deploy.yml -e binary_src=/tmp/gitops-api -e app_version=$VERSION

# PLAY [Deploy gitops-api to app VMs] ***************************************************************************************************************

# TASK [Gathering Facts] ****************************************************************************************************************************
# ok: [app-vm1]

# TASK [Sanity-check required extra-vars] ***********************************************************************************************************
# ok: [app-vm1] => changed=false
#   msg: All assertions passed

# TASK [Sanity-check the binary exists on the controller] *******************************************************************************************
# ok: [app-vm1 -> localhost]

# TASK [Fail if binary missing] *********************************************************************************************************************
# skipping: [app-vm1]

# TASK [Ensure /opt/app/current exists] *************************************************************************************************************
# changed: [app-vm1]

# TASK [Copy gitops-api binary] *********************************************************************************************************************
# changed: [app-vm1]

# TASK [Template systemd unit] **********************************************************************************************************************
# changed: [app-vm1]

# TASK [Enable gitops-api (start handled by handler on first deploy)] *******************************************************************************
# changed: [app-vm1]

# RUNNING HANDLER [Reload systemd] ******************************************************************************************************************
# ok: [app-vm1]

# RUNNING HANDLER [Restart gitops-api] **************************************************************************************************************
# changed: [app-vm1]

# TASK [Flush handlers so smoke test runs against the new binary] ***********************************************************************************

# TASK [Smoke test — GET /healthz] ******************************************************************************************************************
# ok: [app-vm1 -> localhost]

# TASK [Smoke test — GET / reports the expected version] ********************************************************************************************
# ok: [app-vm1 -> localhost]

# TASK [Assert version matches] *********************************************************************************************************************
# ok: [app-vm1] => changed=false
#   msg: All assertions passed

# PLAY [Deploy gitops-api to app VMs] ***************************************************************************************************************

# TASK [Gathering Facts] ****************************************************************************************************************************
# ok: [app-vm2]

# TASK [Sanity-check required extra-vars] ***********************************************************************************************************
# ok: [app-vm2] => changed=false
#   msg: All assertions passed

# TASK [Sanity-check the binary exists on the controller] *******************************************************************************************
# ok: [app-vm2 -> localhost]

# TASK [Fail if binary missing] *********************************************************************************************************************
# skipping: [app-vm2]

# TASK [Ensure /opt/app/current exists] *************************************************************************************************************
# changed: [app-vm2]

# TASK [Copy gitops-api binary] *********************************************************************************************************************
# changed: [app-vm2]

# TASK [Template systemd unit] **********************************************************************************************************************
# changed: [app-vm2]

# TASK [Enable gitops-api (start handled by handler on first deploy)] *******************************************************************************
# changed: [app-vm2]

# RUNNING HANDLER [Reload systemd] ******************************************************************************************************************
# ok: [app-vm2]

# RUNNING HANDLER [Restart gitops-api] **************************************************************************************************************
# changed: [app-vm2]

# TASK [Flush handlers so smoke test runs against the new binary] ***********************************************************************************

# TASK [Smoke test — GET /healthz] ******************************************************************************************************************
# ok: [app-vm2 -> localhost]

# TASK [Smoke test — GET / reports the expected version] ********************************************************************************************
# ok: [app-vm2 -> localhost]

# TASK [Assert version matches] *********************************************************************************************************************
# ok: [app-vm2] => changed=false
#   msg: All assertions passed

# PLAY RECAP ****************************************************************************************************************************************
# app-vm1                    : ok=12   changed=5    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
# app-vm2                    : ok=12   changed=5    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```

- confirm

```sh
curl -s app-vm1:8080/ && echo && curl -s app-vm2:8080/
# {"app":"VM GitOps Practices","version":"0.1.0"}
# {"app":"VM GitOps Practices","version":"0.1.0"}
```
