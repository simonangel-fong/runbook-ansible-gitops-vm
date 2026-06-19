# Ansible Runbook: Implementa GitOps on VMs

- [Ansible Runbook: Implementa GitOps on VMs](#ansible-runbook-implementa-gitops-on-vms)
  - [Challenge](#challenge)
  - [VM-based Environment Architecture](#vm-based-environment-architecture)
  - [GitOps Pipeline](#gitops-pipeline)
    - [Happy Path](#happy-path)
    - [Alternative Path](#alternative-path)

## Challenge

GitOps practices enable progressive deployments, fast rollbacks, and improved reliability. However, many small and medium-sized companies still run applications in VM-based environments rather than Cloud-native envionment.

> How can a VM-based environment implement modern GitOps practices?

- **Project Goals**
  - Reproduce a VM-based application environment using AWS EC2
  - Implement GitOps-style deployment practices for a simple Go REST API
  - Use Jenkins and Ansible to automate deployment, configuration, and rollback workflows

This project is designed as a VM-based counterpart to a `Kubernetes` + `ArgoCD` deployment model, demonstrating how similar GitOps principles can be applied outside of Kubernetes environments.

---

## VM-based Environment Architecture

```txt
                            │
                            │ Public traffic
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│ VPC: 10.0.0.0/16                                                 │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ DMZ Subnet: 10.0.10.0/24                                   │  │
│  │                                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │ gitops-lb                                            │  │  │
│  │  │ 10.0.10.20                                           │  │  │
│  │  │ Nginx reverse proxy / traffic split                  │  │  │
│  │  │ Only internet-facing application host                │  │  │
│  │  └───────────────┬──────────────────────┬───────────────┘  │  │
│  └──────────────────│──────────────────────│──────────────────┘  │
│                     │                      │                     │
│                     │ HTTP :8080           │ HTTP :8080          │
│                     ▼                      ▼                     │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ App Subnet: 10.0.20.0/24                                   │  │
│  │                                                            │  │
│  │  ┌──────────────────────┐        ┌──────────────────────┐  │  │
│  │  │ gitops-app-vm1       │        │ gitops-app-vm2       │  │  │
│  │  │ 10.0.20.11           │        │ 10.0.20.12           │  │  │
│  │  │ Go API + systemd     │        │ Go API + systemd     │  │  │
│  │  │ Canary               │        │ Stable               │  │  │
│  │  └──────────┬───────────┘        └──────────┬───────────┘  │  │
│  └─────────────│───────────────────────────────│──────────────┘  │
│                │                               │                 │
│                │ SSH / Ansible                 │ SSH / Ansible   │
│                │ Metrics scrape                │ Metrics scrape  │
│                ▼                               ▼                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Mgmt Subnet: 10.0.90.0/24                                  │  │
│  │                                                            │  │
│  │  ┌──────────────────────┐        ┌──────────────────────┐  │  │
│  │  │ gitops-jump          │        │ gitops-monitor       │  │  │
│  │  │ 10.0.90.10           │        │ 10.0.90.20           │  │  │
│  │  │ Jenkins              │        │ Prometheus           │  │  │
│  │  │ Ansible              │        │ Grafana              │  │  │
│  │  │ Jump host            │        │ Metrics dashboard    │  │  │
│  │  └──────────────────────┘        └──────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## GitOps Pipeline

### Happy Path

1. **Read release.yaml**:
   - parse declared state into env vars.
2. **Build**:
   - build go artifest based on env vars.
3. **Pre-deploy canary**:
   - deploy canary version on canary instance
   - `ansible-playbook deploy.yml --limit app-vm1`
4. **Canary phase loop**:
   - 20% (60s) -> 50% (60s) -> 100%
   - spilt weighted traffic via nginx
   - health check by `/healthz`
5. **Promote: stable hosts**:
   - deploy canary version on stable instance
6. **Reset LB to balanced**:
   - restore traffic weight via nginx

---

### Alternative Path

1. **Drain LB**:
   - Set canary traffic to `0`.
2. **Rollback canary**:
   - swaps the symlink back, restarts.
3. **Restore balance**:
   - restore traffic weight via nginx
