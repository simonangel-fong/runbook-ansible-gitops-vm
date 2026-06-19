# Monitoring Plan - Phase H

| Field         | Value                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------- |
| Status        | Draft v1                                                                                             |
| Author        | Simon Fong                                                                                           |
| Last updated  | 2026-06-17                                                                                           |
| Companion doc | [plan.md](plan.md), [aws_design.md](aws_design.md)                                                   |
| Scope         | Prometheus + Grafana stack on a new `gitops-mon` VM; app instrumentation; canary-aware dashboard. |

This is the **how**. The "why" sits in the README's "Why VMs" section: monitoring
on a management-VLAN utility VM is the canonical on-prem pattern, and v1 was
missing it. Phase H closes that gap so reviewers can *see* the canary work,
not just read about it.

## 1. Goals

| Goal                                                       | Achieved by                                                                                |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Reviewer sees the canary phases happen, visually           | Grafana panels showing per-VM request rate during the canary loop                          |
| Reviewer sees the failure-demo gate trip + rollback recover | Per-VM `healthy` gauge (red/green) + per-VM error rate spike, then both return to green   |
| Reviewer sees the version transition                       | `gitops_api_info{version=...,host=...}` gauge - Grafana shows which VM serves which version |
| README has embeddable screenshots instead of long prose    | Stable dashboard URL + 3-4 screenshots embedded in README                                  |

## 2. Out of Scope (Explicit Non-Goals)

Calling these out so the project doesn't drift into a Prometheus tutorial.

- **Prometheus-driven canary gate.** The Jenkinsfile's health gate continues
  to use SSH-curl against `/healthz`. Replacing it with a PromQL query is the
  natural next step (matches what Flagger / Argo Rollouts do) but it's a
  separate phase. Plan keeps the v1 gate.
- **Jenkins-to-Grafana annotations.** Pipeline does **not** post annotations
  to Grafana on deploy/rollback events. Monitoring lives outside the pipeline
  entirely (Q1 - see below). Annotations are a polish item, deferred.
- **AlertManager / paging.** No alerts wired up. The dashboard is for
  human-watched demo, not on-call.
- **node_exporter on app VMs.** Skipped - CPU/mem panels would be cosmetic
  (the demo is about traffic + health, not resource pressure). Adding
  node_exporter is a 30-min follow-up if needed.
- **nginx_exporter on lb.** Skipped for the same reason - the app's own
  metrics already tell the traffic-split story; nginx upstream weights
  would duplicate the signal.
- **Long-term storage / federation.** Local Prometheus tsdb with default
  retention. Demo doesn't need history past one cycle.

## 3. Design Decisions (Recorded)

| #   | Question                                              | Decision                                                                                         | Why                                                                                                                                |
| --- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Q1  | Should the pipeline interact with monitoring?         | **No.** Monitoring runs outside the pipeline entirely.                                           | Keeps the failure-demo story honest: Prometheus is an independent observer, not a participant. Easier to reason about, less coupling. |
| Q2  | Does Prometheus fit the on-prem narrative?            | **Yes - explicit part of the story.**                                                            | "Monitoring on the management VLAN" is exactly how on-prem ops shops do this. Updates `aws_design.md` §2 to reflect.               |
| Q3  | Inline metrics in `app/main.go` or a separate package? | **Inline in the same Go module.** Add a few lines to `main.go` and a metrics handler to `handlers.go`. | Three or four metrics doesn't justify a `metrics/` package. Extract later if it grows.                                              |

## 4. Topology Change

`gitops-mon` joins the fleet as the fifth VM. Lives in the **Mgmt subnet**
alongside `gitops-jump`.

```
VPC  10.0.0.0/16

├─ DMZ subnet           10.0.10.0/24
│   └── gitops-lb       10.0.10.20
│
├─ App subnet           10.0.20.0/24
│   ├── gitops-app-vm1  10.0.20.11
│   └── gitops-app-vm2  10.0.20.12
│
└─ Mgmt subnet          10.0.90.0/24
    ├── gitops-jump     10.0.90.10
    └── gitops-mon      10.0.90.20      ← new
```

No EIP on mon. UI access is via SSH tunnel through `jump`, identical to
Jenkins. That keeps the on-prem-style "management VLAN is never on the
public internet" invariant intact.

## 5. Instance Spec

| Item          | Value                                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------------------------ |
| Name tag      | `gitops-mon`                                                                                                       |
| Type          | `t3.small` (Prometheus + Grafana on `t3.micro` is tight; ~$8/mo upgrade)                                            |
| Subnet        | mgmt (`10.0.90.0/24`)                                                                                              |
| Private IP    | `10.0.90.20`                                                                                                       |
| Public IP     | None                                                                                                               |
| Keypair       | Reuses `aws_key_pair.fleet`                                                                                        |
| AMI           | Same `data.aws_ami.ubuntu` (Noble 24.04)                                                                            |
| user_data     | None - Ansible handles the install (consistent with how jump differs from the rest of the fleet; mon mirrors apps) |

## 6. Security Groups

New `sg-mon`. Modifications to two existing SGs.

| SG        | Rule          | Ingress / Egress                  | Why                                                |
| --------- | ------------- | --------------------------------- | -------------------------------------------------- |
| `sg-mon`  | ingress 22    | from `sg-jump`                    | Ansible-from-jump bootstrap                        |
| `sg-mon`  | ingress 9090  | from `sg-jump`                    | Prometheus UI via SSH tunnel (debugging)           |
| `sg-mon`  | ingress 3000  | from `sg-jump`                    | Grafana UI via SSH tunnel (the actual demo signal) |
| `sg-mon`  | egress        | All (`0.0.0.0/0`)                 | Needs apt for Prometheus/Grafana install - same posture as `sg-jump` |
| `sg-app`  | +ingress 8080 | from `sg-mon`                     | Prometheus scrapes `app-vm1:8080/metrics`           |
| `sg-jump` | unchanged     |                                   | Tunnels to mon work as a function of `sg-mon` ingress, not jump egress |

`sg-mon` egress is open to `0.0.0.0/0` - same posture as `sg-jump`. Ansible
installs Prometheus and Grafana from apt mirrors at run time, which needs
egress to the internet. Scrapes themselves are still VPC-internal.

## 7. File Layout

New files, following the existing numeric-prefix convention.

```
infra/
└── 11_ec2_mon.tf          # gitops-mon: SG + instance + sg-app/sg-mon glue rule

ansible/
├── mon.yml                # new playbook - installs prometheus + grafana on gitops-mon
└── roles/
    ├── prometheus/
    │   ├── tasks/main.yml
    │   ├── templates/
    │   │   └── prometheus.yml.j2   # scrape config
    │   └── handlers/main.yml       # systemctl reload prometheus
    └── grafana/
        ├── tasks/main.yml
        ├── templates/
        │   └── datasource.yml.j2   # prometheus datasource auto-provisioned
        └── files/
            └── canary-dashboard.json   # the deliverable

app/
├── main.go                # +imports prometheus client; +metrics middleware
└── handlers.go            # +metricsHandler (a one-liner promhttp wrapper)
```

`bootstrap.yml` stays scoped to first-touch fleet setup (appuser, nginx
install, app dirs). `mon.yml` is its own playbook because it's
orthogonal - re-runnable independently when iterating on the dashboard.

## 8. Phased Build Order

| Phase | What                                                  | Verifiable by                                                                                                                  |
| ----- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| H1    | Instrument Go app - `/metrics` endpoint                | `curl localhost:8080/metrics` shows prometheus text format with `gitops_api_*` metrics                                          |
| H2    | Terraform - add `gitops-mon` VM + SG rules            | `terraform apply` succeeds; `ssh jump 'nc -zv 10.0.90.20 22'` returns succeeded                                                  |
| H3    | Ansible - install Prometheus + Grafana on mon         | `ssh mon 'systemctl is-active prometheus grafana-server'` returns active for both                                              |
| H4    | Prometheus scrape config (static targets)             | Prometheus UI (via SSH tunnel) shows `gitops-api` targets UP                                                                    |
| H5    | Grafana dashboard (provisioned JSON)                  | Grafana UI shows the canary dashboard; trigger a happy-path deploy and watch panels update                                      |
| H6    | Run failure demo, capture screenshots, update README  | README has embedded images instead of prose for the canary + rollback sequences                                                |

Each phase is committable and demoable on its own. If a phase blocks, the
previous phases are still working.

## 9. The Four Metrics

Smallest set that tells the story:

| Metric                                              | Type      | What it shows in Grafana                                                                                |
| --------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------- |
| `gitops_api_requests_total{path,code,host}`         | counter   | Per-VM request rate as a stacked area - canary phases become visually obvious                            |
| `gitops_api_request_duration_seconds{path,host}`    | histogram | p95 latency per VM - broken canary often shows latency change too                                       |
| `gitops_api_info{version,host}`                     | gauge (1) | "Which version is each VM serving?" - table panel, updates during canary deploy                          |
| `gitops_api_healthy{host}`                          | gauge 0/1 | Big red/green stat panel per VM - drops to 0 the moment `build_healthy: false` deploy lands              |

`host` label comes from `os.Hostname()` - same value already in the JSON
response. Labels make the canary-vs-stable distinction navigable in PromQL
without hard-coding VM names.

## 10. The Dashboard

Single Grafana dashboard, provisioned from
`ansible/roles/grafana/files/canary-dashboard.json`. Six panels in two rows.

**Row 1 - "what's happening right now"**

| Panel                       | Type        | Query (shape)                                                              |
| --------------------------- | ----------- | -------------------------------------------------------------------------- |
| Currently serving           | Table       | `gitops_api_info` grouped by `host, version`                               |
| Healthy status              | Stat (gauge per host) | `gitops_api_healthy` - red when 0, green when 1                  |

**Row 2 - "what happened during the canary"**

| Panel                       | Type        | Query (shape)                                                              |
| --------------------------- | ----------- | -------------------------------------------------------------------------- |
| Requests per second per VM  | Stacked area| `sum by (host) (rate(gitops_api_requests_total[30s]))`                     |
| Error rate per VM           | Time series | `sum by (host) (rate(gitops_api_requests_total{code=~"5.."}[30s]))`        |
| p95 latency per VM          | Time series | `histogram_quantile(0.95, sum by (le, host) (rate(..._bucket[1m])))`        |
| 5xx ratio per VM            | Time series | error rate / total rate per host - the metric a real canary gate would use |

The last panel exists to set up the "next step" narrative: this is *the*
signal a Prometheus-driven gate would use, and it's right there in the
dashboard.

## 11. Access Pattern

Grafana on port 3000, SSH-tunneled like Jenkins:

```powershell
ssh -i keys/gitops-vm.pem `
    -L 3000:10.0.90.20:3000 `
    -L 9090:10.0.90.20:9090 `
    ubuntu@$(terraform -chdir=infra output -raw jump_public_ip)
```

Then browser to `http://localhost:3000` (Grafana) or `http://localhost:9090`
(Prometheus). Two new Terraform outputs in `04_output.tf`:

```hcl
output "grafana_tunnel"   { value = "ssh ... -L 3000:10.0.90.20:3000 ..." }
output "prometheus_tunnel"{ value = "ssh ... -L 9090:10.0.90.20:9090 ..." }
```

## 12. Updates to Existing Docs

- **[aws_design.md](aws_design.md) §2** - Move "Prometheus + node_exporter"
  from "not modelled in v1" to a new row in the on-prem-patterns table:
  "Agent-based monitoring on a management VLAN host → `gitops-mon` runs
  Prometheus + Grafana".
- **[aws_design.md §5](aws_design.md)** - Add `gitops-mon` to the instance
  table.
- **[aws_design.md §6](aws_design.md)** - Add `sg-mon` row + `sg-app`
  ingress note.
- **[aws_design.md §11](aws_design.md)** - Cost table: +~$17/mo for the
  `t3.small`.
- **README** - "Out of scope" section: remove Prometheus line. Add the
  dashboard screenshots to a new "What the demo looks like" section.

## 13. Risks and Open Questions

1. **Grafana version drift between Ubuntu 24.04 repo and current.** Ubuntu's
   `grafana` apt package may lag the upstream by a year. Use upstream
   repo (`packages.grafana.com/oss/deb`) following the same pattern as the
   Jenkins install - adds an apt sources file, imports a GPG key. Decided.
2. **Provisioning timing.** Grafana's "provisioning" feature reads
   `/etc/grafana/provisioning/dashboards/*.yml` at startup. The dashboard
   JSON has to be on disk before Grafana starts, or the role has to notify
   a restart. Going with the restart pattern.
3. **Prometheus scrape interval vs canary phase timing.** Canary phases
   hold for 15s in the demo. A 15-second scrape interval is too coarse -
   you'd only get one data point per phase. **Decision: 5s scrape interval**
   so each phase shows 3 data points.
4. **Dashboard JSON drift.** Iterating on the dashboard in the Grafana UI
   produces a new JSON each time. Need a workflow for "edit in UI, export,
   commit". Documented in the role's task comments.

## 14. Cost Impact

| Item                                            | Quantity | Approx. monthly |
| ----------------------------------------------- | -------- | --------------- |
| `t3.small` `gitops-mon`                         | 1        | ~$17            |
| EBS gp3 30 GB                                   | 1        | ~$3             |
| Data transfer (scrapes are VPC-internal, free) | -        | $0              |
| **Phase H total**                               |          | **~$20/mo**     |

Brings the full project to ~$65/mo if left running, still ~$0 with
`terraform destroy` between demo cycles.

## 15. Done When

Phase H is complete when:

- [ ] Grafana dashboard renders with all six panels populated by live data.
- [ ] Running a healthy deploy causes "Requests per second per VM" to show
      traffic shifting through canary phases.
- [ ] Running a `build_healthy: false` deploy causes:
  - "Healthy status" panel to flip red for app-vm1
  - "Error rate per VM" panel to spike for app-vm1
  - All panels to return to steady state after rollback finishes
- [ ] README has 3-4 screenshots captured during the failure demo, replacing
      the text-only "How To Demo This" subsection.
- [ ] `aws_design.md` updated per §12.
