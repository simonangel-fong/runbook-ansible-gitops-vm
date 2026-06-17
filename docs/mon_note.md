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
# # HELP gitops_api_info Build info — always 1, labels carry version and host.
# # TYPE gitops_api_info gauge
# gitops_api_info{host="Simon-Laptop",version="dev"} 1
# # HELP gitops_api_request_duration_seconds HTTP request duration in seconds, labelled by matched route and host.
# # TYPE gitops_api_request_duration_seconds histogram
# gitops_api_request_duration_seconds_bucket{host="Simon-Laptop",path="/",le="0.005"} 1
# gitops_api_request_duration_seconds_bucket{host="Simon-Laptop",path="/",le="0.01"} 1
```

---

## Mon instance

```sh
terraform -chdir=infra apply -auto-approve

terraform -chdir=infra output ssh_jump

# on jump
ansible mon -m ping
# mon | SUCCESS => {
#     "changed": false,
#     "ping": "pong"
# }

# install
ansible-playbook mon.yml


ssh mon 'systemctl is-active prometheus grafana-server'
# active
# active

# prom UI
ssh -i infra/keys/gitops-vm.pem -L 9090:10.0.90.20:9090 ubuntu@16.52.182.125

# http://localhost:9090/targets
```