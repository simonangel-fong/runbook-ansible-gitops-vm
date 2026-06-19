# GitOps VM: Init Jenkins

[Back](../README.md)

- [GitOps VM: Init Jenkins](#gitops-vm-init-jenkins)
  - [Login jenkins](#login-jenkins)

---

## Login jenkins

```sh
# forward jenkins UI
terraform -chdir=infra/ output -raw jenkins_tunnel
# ssh -i infra/keys/gitops-vm.pem -L 8080:localhost:8080 ubuntu@16.52.14.216

# Confirm jenkins
systemctl status jenkins      # active (running)
# ● jenkins.service - Jenkins Continuous Integration Server
#      Loaded: loaded (/usr/lib/systemd/system/jenkins.service; enabled; preset: enabled)
#      Active: active (running) since Fri 2026-06-19 20:37:03 UTC; 53s ago
#    Main PID: 8436 (java)
#       Tasks: 48 (limit: 4520)
#      Memory: 585.8M (peak: 592.0M)
#         CPU: 21.337s
#      CGroup: /system.slice/jenkins.service

ssh -i infra/keys/gitops-vm.pem -L 8080:localhost:8080 ubuntu@16.52.14.216

# init pwd
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

- Install plugins:
  - sshagent
  - Pipeline Utility Steps
  - Stage View
- credential
  - fleet-key
- Set pipeline
  - url: https://github.com/simonangel-fong/runbook-ansible-gitops-vm.git
  - pipeline path: jenkins/Jenkinsfile.deploy

![jenkins_ui](./pic/jenkins_ui.png)

