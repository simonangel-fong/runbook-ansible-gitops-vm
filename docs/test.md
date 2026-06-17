- stable version

```sh
# app/VERSION: replace contents
echo "0.3.0" > app/VERSION

cat app/VERSION                              # -> 0.3.0
grep -E 'version|build_healthy' deploy/release.yaml
# expect:  version: "0.3.0"
#          build_healthy: true

# Commit + push
git add app/VERSION deploy/release.yaml
git commit -m "release: 0.3.0"
git push
```

- fail version

```sh
echo "0.3.1-broken" > app/VERSION
grep -E 'version|build_healthy' deploy/release.yaml
# expect:  version: "0.3.1-broken"
#          build_healthy: false

git add .
git commit -m "demo: trigger rollback"
git push
```