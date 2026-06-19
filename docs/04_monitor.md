# GitOps VM: Monitoring - Prometheus + Grafana

[Back](../README.md)

- [GitOps VM: Monitoring - Prometheus + Grafana](#gitops-vm-monitoring---prometheus--grafana)
  - [Golang metrics](#golang-metrics)
  - [Login Monitor Instance](#login-monitor-instance)
    - [Prometheus UI](#prometheus-ui)
    - [Grafana UI](#grafana-ui)

---

## Golang metrics

```sh
go get github.com/prometheus/client_golang/prometheus
go get github.com/prometheus/client_golang/prometheus/promhttp
```

- Test

```sh
go test .
# ok      gitops-vm       (cached)

go run .

curl http://localhost:8080
# {"app":"VM GitOps Practices","host":"localhost","version":"dev"}
curl http://localhost:8080/healthz
# ok
curl http://localhost:8080/metrics
# # HELP gitops_api_healthy 1 if the instance reports healthy, 0 otherwise.
# # TYPE gitops_api_healthy gauge
# gitops_api_healthy{host="Simon-Laptop"} 1
# # HELP gitops_api_info Build info - always 1, labels carry version and host.
# # TYPE gitops_api_info gauge
# gitops_api_info{host="Simon-Laptop",version="dev"} 1
# # HELP gitops_api_request_duration_seconds HTTP request duration in seconds, labelled by matched route and host.
# # TYPE gitops_api_request_duration_seconds histogram
# gitops_api_request_duration_seconds_bucket{host="Simon-Laptop",path="/",le="0.005"} 1
# gitops_api_request_duration_seconds_bucket{host="Simon-Laptop",path="/",le="0.01"} 1
```

---

## Login Monitor Instance

```sh
terraform -chdir=infra apply -auto-approve

terraform -chdir=infra output ssh_jump

# on jump
cd ~/runbook-ansible-gitops-vm/ansible/
ansible mon -m ping -o
# mon | SUCCESS => {"changed": false,"ping": "pong"}

# install
ansible-playbook mon.yml

# confirm prometheus grafana is active
ssh mon 'systemctl is-active prometheus grafana-server'
# active
# active
```

---

### Prometheus UI

```sh
# prom UI
terraform -chdir=infra/ output -raw prometheus_tunnel
# ssh -i infra/keys/gitops-vm.pem -L 9090:10.0.90.20:9090 ubuntu@16.52.14.216

ssh -i infra/keys/gitops-vm.pem -L 9090:10.0.90.20:9090 ubuntu@16.52.14.216

# http://localhost:9090/classic/targets
```

![prometheus_ui](./pic/prom_ui.png)

---

### Grafana UI

```sh
terraform -chdir=infra/ output -raw grafana_tunnel
# ssh -i infra/keys/gitops-vm.pem -L 3000:10.0.90.20:3000 ubuntu@16.52.14.216

ssh -i infra/keys/gitops-vm.pem -L 3000:10.0.90.20:3000 ubuntu@16.52.14.216

# grafana UI
# http://localhost:3000
```

![grafana_login](./pic/grafana_login.png)
