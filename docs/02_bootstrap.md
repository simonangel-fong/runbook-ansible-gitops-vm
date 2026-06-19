# GitOps VM: Bootstrap Environment

[Back](../README.md)

- [GitOps VM: Bootstrap Environment](#gitops-vm-bootstrap-environment)
  - [Boostrap VM-based Environment via Ansible](#boostrap-vm-based-environment-via-ansible)
  - [Deploy init Version](#deploy-init-version)
    - [Build Go](#build-go)
    - [Deploy app via ansible](#deploy-app-via-ansible)

---

## Boostrap VM-based Environment via Ansible

```sh
cd ~/runbook-ansible-gitops-vm/ansible
ansible all -m ping -o
# jump | SUCCESS => {"changed": false,"ping": "pong"}
# lb | SUCCESS => {"changed": false,"ping": "pong"}
# app-vm1 | SUCCESS => {"changed": false,"ping": "pong"}
# mon | SUCCESS => {"changed": false,"ping": "pong"}
# app-vm2 | SUCCESS => {"changed": false,"ping": "pong"}

# Bootstrap
ansible-playbook bootstrap.yml
# PLAY [A2 — Connectivity check (every fleet host)] *************************************************************

# TASK [Ping] ***************************************************************************************************
# ok: [app-vm1]
# ok: [mon]
# ok: [lb]
# ok: [app-vm2]

# PLAY [A3a — LB base setup] ************************************************************************************

# TASK [Gathering Facts] ****************************************************************************************
# ok: [lb]

# TASK [Install nginx] ******************************************************************************************
# changed: [lb]

# TASK [Enable nginx (do not start — no upstream config yet)] ***************************************************
# ok: [lb]

# PLAY [A3b — App VM base setup] ********************************************************************************

# TASK [Gathering Facts] ****************************************************************************************
# ok: [app-vm1]
# ok: [app-vm2]

# TASK [Create appuser] *****************************************************************************************
# changed: [app-vm1]
# changed: [app-vm2]

# TASK [Create /opt/app layout] *********************************************************************************
# changed: [app-vm2] => (item=/opt/app)
# changed: [app-vm1] => (item=/opt/app)
# changed: [app-vm2] => (item=/opt/app/releases)
# changed: [app-vm1] => (item=/opt/app/releases)

# PLAY RECAP ****************************************************************************************************
# app-vm1                    : ok=4    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
# app-vm2                    : ok=4    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
# lb                         : ok=4    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
# mon                        : ok=1    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0

```

---

## Deploy init Version

### Build Go

```sh
cd ~/runbook-ansible-gitops-vm/app
VERSION=$(cat VERSION)
go build -ldflags "-X main.version=$VERSION" -o /tmp/gitops-api .
ls -la /tmp/gitops-api
# -rwxrwxr-x 1 ubuntu ubuntu 33719367 Jun 19 20:54 /tmp/gitops-api
```

### Deploy app via ansible

```sh
cd ~/runbook-ansible-gitops-vm/ansible
ansible-playbook deploy.yml -e binary_src=/tmp/gitops-api -e app_version=$VERSION

# confirm
curl -s app-vm1:8080/ && echo && curl -s app-vm2:8080/
# {"app":"VM GitOps Practices","host":"ip-10-0-20-11","version":"0.3.1"}
# {"app":"VM GitOps Practices","host":"ip-10-0-20-12","version":"0.3.1"}
```
