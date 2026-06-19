# GitOps VM: Test - Alternative Path

[Back](../README.md)

- [GitOps VM: Test - Alternative Path](#gitops-vm-test---alternative-path)
  - [Test - Alternative Path](#test---alternative-path)
  - [Revert](#revert)

---

## Test - Alternative Path

- buggy version

```sh
# app/VERSION: replace contents
echo "0.3.2" > app/VERSION

cat app/VERSION                              # -> 0.3.2
grep -E 'version|build_healthy' deploy/release.yaml
# expect:  version: "0.3.2"
#          build_healthy: false

# Commit + push
git add .
git commit -m "release: 0.3.2"
git push
```

![alternative01](./pic/test_alternative01.png)

![alternative02](./pic/test_alternative02.png)

- Confirm
  - app rollback

```sh
# jump
curl -s app-vm1:8080
# {"app":"VM GitOps Practices","host":"ip-10-0-20-11","version":"0.3.1"}
curl -s app-vm2:8080
# {"app":"VM GitOps Practices","host":"ip-10-0-20-12","version":"0.3.1"}

# test lb public ip
curl -s 3.98.220.13
# {"app":"VM GitOps Practices","host":"ip-10-0-20-11","version":"0.3.1"}
curl -s 3.98.220.13
# {"app":"VM GitOps Practices","host":"ip-10-0-20-12","version":"0.3.1"}
```

## Revert

- buggy version

```sh
# app/VERSION: replace contents
echo "0.3.1" > app/VERSION

cat app/VERSION                              # -> 0.3.1
grep -E 'version|build_healthy' deploy/release.yaml
# expect:  version: "0.3.2"
#          build_healthy: true

# Commit + push
git add .
git commit -m "release: 0.3.1"
git push
```