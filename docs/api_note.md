# API Build Notes

## Phase 1 — Scaffold and hello world

**Goal.** Project compiles and serves a hardcoded response on `:8080`.

### Commands (PowerShell, run from repo root)

```sh
# 1. Create the app/ folder
mkdir app
cd app

# 2. Init the Go module
go mod init gitops-vm
# go: creating new go.mod: module gitops-vm

# 3. Add gin dependency
go get github.com/gin-gonic/gin

# 4. Write VERSION (placeholder — not wired via -ldflags until Phase 3)
tee VERSION<<EOF
"0.1.0"
EOF
```

- `app/main.go`

```go
package main

import "github.com/gin-gonic/gin"

func main() {
	r := gin.Default()
	r.GET("/", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"app":     "VM GitOps Practices",
			"version": "dev",
		})
	})
	r.Run(":8080")
}
```

### Verify "Done when"

Terminal A:

```sh
go run ./app
# [GIN-debug] [WARNING] Creating an Engine instance with the Logger and Recovery middleware already attached.

# [GIN-debug] [WARNING] Running in "debug" mode. Switch to "release" mode in production.
#  - using env:   export GIN_MODE=release
#  - using code:  gin.SetMode(gin.ReleaseMode)

# [GIN-debug] GET    /                         --> main.main.func1 (3 handlers)
# [GIN-debug] [WARNING] You trusted all proxies, this is NOT safe. We recommend you to set a value.
# Please check https://github.com/gin-gonic/gin/blob/master/docs/doc.md#dont-trust-all-proxies for details.
# [GIN-debug] Listening and serving HTTP on :8080
# [GIN] 2026/06/15 - 21:20:44 | 200 |       0s |             ::1 | GET      "/"
# [GIN] 2026/06/15 - 21:20:44 | 404 |  309.3µs |             ::1 | GET      "/favicon.ico"

curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"dev"}
```

Stop the server with Ctrl+C in Terminal A when done.

- Confim Files created

- `app/VERSION`
- `app/go.mod`
- `app/go.sum`
- `app/main.go`

---

## Phase 2

**Goal.** `/` and `/healthz` work; handler logic separated from server setup.

```go
// app/handlers.go
package main

import "github.com/gin-gonic/gin"

func rootHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"app":     "VM GitOps Practices",
		"version": "dev",
	})
}

func healthzHandler(c *gin.Context) {
	c.String(200, "ok")
}
```

```go
// app/main.go
package main

import "github.com/gin-gonic/gin"

func main() {
	r := gin.Default()

    // GET /
	r.GET("/", rootHandler)

    // GET /healthz
	r.GET("/healthz", healthzHandler)

    // port
	r.Run(":8080")
}
```

### Verify "Done when"

Terminal A:

```sh
cd app
go run .
# [GIN-debug] [WARNING] Creating an Engine instance with the Logger and Recovery middleware already attached.

# [GIN-debug] [WARNING] Running in "debug" mode. Switch to "release" mode in production.
#  - using env:   export GIN_MODE=release
#  - using code:  gin.SetMode(gin.ReleaseMode)

# [GIN-debug] GET    /                         --> main.rootHandler (3 handlers)
# [GIN-debug] GET    /healthz                  --> main.healthzHandler (3 handlers)
# [GIN-debug] [WARNING] You trusted all proxies, this is NOT safe. We recommend you to set a value.
# Please check https://github.com/gin-gonic/gin/blob/master/docs/doc.md#dont-trust-all-proxies for details.
# [GIN-debug] Listening and serving HTTP on :8080
# [GIN] 2026/06/15 - 21:33:13 | 200 |       0s |             ::1 | GET      "/"
# [GIN] 2026/06/15 - 21:33:23 | 200 |       0s |             ::1 | GET      "/healthz"
# [GIN] 2026/06/15 - 21:33:30 | 200 |       0s |             ::1 | GET      "/healthz"
```

Terminal B:

```sh
curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"dev"}

curl http://localhost:8080/healthz
# ok

curl -i http://localhost:8080/healthz
# HTTP/1.1 200 OK
# Content-Type: text/plain; charset=utf-8
# Date: Tue, 16 Jun 2026 01:33:30 GMT
# Content-Length: 2

# ok
```

- Confirm files created / changed

- `app/handlers.go`
- `app/main.go`

---

## Phase 3

**Goal.** The version in `GET /` comes from `app/VERSION`, set at build time.
Default stays `"dev"` so `go run` still works without the build command.

### Files

```go
// app/main.go
package main

import "github.com/gin-gonic/gin"

var version = "dev"

func main() {
	r := gin.Default()

	// GET /
	r.GET("/", rootHandler)

	// GET /healthz
	r.GET("/healthz", healthzHandler)

	// port
	r.Run(":8080")
}
```

```go
// app/handlers.go
package main

import "github.com/gin-gonic/gin"

func rootHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"app":     "VM GitOps Practices",
		"version": version,
	})
}

func healthzHandler(c *gin.Context) {
	c.String(200, "ok")
}
```

### Verify "Done when"

```sh
cd app
go run .
# [GIN-debug] [WARNING] Creating an Engine instance with the Logger and Recovery middleware already attached.

# [GIN-debug] [WARNING] Running in "debug" mode. Switch to "release" mode in production.
#  - using env:   export GIN_MODE=release
#  - using code:  gin.SetMode(gin.ReleaseMode)

# [GIN-debug] GET    /                         --> main.rootHandler (3 handlers)
# [GIN-debug] GET    /healthz                  --> main.healthzHandler (3 handlers)
# [GIN-debug] [WARNING] You trusted all proxies, this is NOT safe. We recommend you to set a value.
# Please check https://github.com/gin-gonic/gin/blob/master/docs/doc.md#dont-trust-all-proxies for details.
# [GIN-debug] Listening and serving HTTP on :8080
# [GIN] 2026/06/15 - 21:42:00 | 200 |       0s |             ::1 | GET      "/"
```

```sh
curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"dev"}
```

Ctrl+C the server.

---

**Check B — built binary picks up VERSION:**

```sh
cd app

VERSION=$(cat app/VERSION)
# build
go build -ldflags "-X main.version=${VERSION}" -o gitops-api
# go build -ldflags "-X main.version=0.1.0" -o gitops-api.exe

# run
./gitops-api
gitops-api.exe
# [GIN-debug] Listening and serving HTTP on :8080
```

```sh
curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"0.1.0"}
```

Ctrl+C the server.

- Confirm files created / changed

- `app/VERSION` (cleaned to `0.1.0` with no quotes)
- `app/main.go` (added `var version = "dev"`)
- `app/handlers.go` (reads `version` variable)
- `gitops-api` (build artifact, not committed)

---

## Phase 4

**Goal.** A `healthy=false` build returns `500 unhealthy` on `/healthz`.
Default build (`healthy=true`) returns `200 ok`. `/` is unaffected.

Notes on the design:

- `-ldflags -X` can only set string vars, so `healthy` is a **string**, not a bool.
- The flag is a _test hook_, not a feature — no debug endpoint exposes its value.
- Default is `"true"` (healthy) so the natural state needs no override; only
  the rollback-demo build sets `healthy=false`.

### Files

```go
// app/main.go
package main

import "github.com/gin-gonic/gin"

var version = "dev"
var healthy = "true"

func main() {
	r := gin.Default()

	// GET /
	r.GET("/", rootHandler)

	// GET /healthz
	r.GET("/healthz", healthzHandler)

	// port
	r.Run(":8080")
}
```

```go
// app/handlers.go
package main

import "github.com/gin-gonic/gin"

func rootHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"app":     "VM GitOps Practices",
		"version": version,
	})
}

func healthzHandler(c *gin.Context) {
	if healthy != "true" {
		c.String(500, "unhealthy")
		return
	}
	c.String(200, "ok")
}
```

### Verify "Done when"

- default build: healthy

```sh
cd app
# From repo root
VERSION=$(cat app/VERSION)
go build -ldflags "-X main.version=${VERSION} -X main.healthy=true" -o gitops-api.exe
# go build -ldflags "-X main.version=0.1.0 -X main.healthy=true" -o gitops-api.exe

gitops-api.exe
```

```sh
curl -i http://localhost:8080/healthz
# HTTP/1.1 200 OK
# Content-Type: text/plain; charset=utf-8
# Date: Tue, 16 Jun 2026 02:02:06 GMT
# Content-Length: 2

# ok

curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"0.1.0"}
```

- failure build:
  - returns 500 on /healthz, / still works:\*\*

```sh
VERSION=$(cat app/VERSION)
go build -ldflags "-X main.version=${VERSION} -X main.healthy=false" -o gitops-api-bad
go build -ldflags "-X main.version=0.1.1 -X main.healthy=false" -o gitops-api-bad.exe

gitops-api-bad.exe
```

```sh
curl -i http://localhost:8080/healthz
# HTTP/1.1 500 Internal Server Error
# Content-Type: text/plain; charset=utf-8
# Content-Length: 9
#
# unhealthy

curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"0.1.1"}
```

Ctrl+C the server.

- no debug endpoint reveals the flag

```sh
curl -i http://localhost:8080/debug
# HTTP/1.1 404 Not Found

curl -i http://localhost:8080/healthy
# HTTP/1.1 404 Not Found
```

- Confirm files created / changed

- `app/main.go` (added `var healthy = "true"`)
- `app/handlers.go` (`/healthz` branches on `healthy`)
- `gitops-api` (default build, healthy)
- `gitops-api-bad` (failure-injection build, returns 500 on `/healthz`)

---

## Phase 5

**Goal.** `SIGTERM` triggers a 10s drain. New connections refused, in-flight
requests complete, then the process exits. This is what stops
`systemctl restart` from killing connections mid-canary.

### Files

```go
// app/main.go
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

var version = "dev"
var healthy = "true"

func main() {
	r := gin.Default()

	// GET /
	r.GET("/", rootHandler)

	// GET /healthz
	r.GET("/healthz", healthzHandler)

	srv := &http.Server{
		Addr:    ":8080",
		Handler: r,
	}

	// Run the server in a goroutine so main can wait on signals.
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %s\n", err)
		}
	}()

	// Wait for SIGINT (Ctrl+C) or SIGTERM (systemctl stop/restart).
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down")

	// 10s drain — in-flight requests complete; new ones rejected.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("forced shutdown: %s\n", err)
	}
	log.Println("server exited cleanly")
}
```

`handlers.go` is unchanged from Phase 4.

### Verify "Done when"

- SIGTERM exits cleanly

Terminal A:

```sh
cd app
go run .
```

Terminal B — send SIGTERM:

```sh
# Linux / Mac / Git Bash on Windows
kill -TERM $(pgrep -f "exe/app|gitops-api")
```

Terminal A should print:

```
shutting down
server exited cleanly
```

and exit within 10s.

**Check B — new connections refused after SIGTERM:**

```sh
curl http://localhost:8080/healthz
# curl: (7) Failed to connect to localhost port 8080: Connection refused
```

**Check C — in-flight request completes (manual drain check):**

Temporarily add a slow route to `main.go` *before* this check, then remove
it before committing:

```go
r.GET("/sleep", func(c *gin.Context) {
	time.Sleep(5 * time.Second)
	c.String(200, "done")
})
```

Terminal B (start the slow request):

```sh
curl http://localhost:8080/sleep &
```

Within ~1s, Terminal C sends SIGTERM:

```sh
kill -TERM $(pgrep -f "exe/app|gitops-api")
```

Terminal A logs `shutting down`. The `curl` from Terminal B still completes
with `done` ~4s later, *before* the server exits. New requests in the
meantime are refused.

Remove the `/sleep` route before committing.

### PowerShell equivalents (Windows host)

PowerShell does not have `pkill` / `kill -TERM`. Windows has no real
`SIGTERM` — the closest local approximation is Ctrl+C in the console where
the server is running, which the Go runtime maps to `SIGINT`, and our
`signal.Notify` catches that path too.

```powershell
# In the server's console window:
# Press Ctrl+C — should log "shutting down" then "server exited cleanly"
```

For the most faithful test of `SIGTERM` + `systemctl` behavior, run this
phase under WSL or on the actual EC2 target (AL2023). Local Windows is fine
for Check A via Ctrl+C; Check C is worth doing once on Linux before
declaring the phase done.

- Confirm files created / changed

- `app/main.go` (replaced `r.Run` with explicit `http.Server` + signal handling)
- `app/handlers.go` (unchanged)

### Notes / adjustments

_(record anything you had to change.)_

### Next

Phase 6 — three `httptest` tests (root, healthy `/healthz`, failing `/healthz`).

---

## Phase 6

**Goal.** One `httptest` test per behavior. Confirms the contract holds; runs
in milliseconds. Three tests total — root, healthy `/healthz`, failing
`/healthz`. No coverage chasing.

Notes on the design:

- Tests live in `app/handlers_test.go` (same package `main`, so they can read
  and mutate `version` and `healthy`).
- Each test builds its own `gin.New()` engine and registers only the route
  under test — keeps each test isolated from `main.go`'s wiring.
- `gin.SetMode(gin.TestMode)` silences gin's debug logging in test output.
- The healthy/failing healthz tests set the package-level `healthy` var
  directly. Use `t.Cleanup` to restore it so test order doesn't matter.

### Files

```go
// app/handlers_test.go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func TestRootHandler(t *testing.T) {
	// Pin version so the assertion is deterministic.
	original := version
	version = "test-1.2.3"
	t.Cleanup(func() { version = original })

	r := gin.New()
	r.GET("/", rootHandler)

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", w.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["app"] != "VM GitOps Practices" {
		t.Errorf("app: got %q, want %q", body["app"], "VM GitOps Practices")
	}
	if body["version"] != "test-1.2.3" {
		t.Errorf("version: got %q, want %q", body["version"], "test-1.2.3")
	}
}

func TestHealthzHealthy(t *testing.T) {
	original := healthy
	healthy = "true"
	t.Cleanup(func() { healthy = original })

	r := gin.New()
	r.GET("/healthz", healthzHandler)

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", w.Code)
	}
	if w.Body.String() != "ok" {
		t.Errorf("body: got %q, want %q", w.Body.String(), "ok")
	}
}

func TestHealthzFailing(t *testing.T) {
	original := healthy
	healthy = "false"
	t.Cleanup(func() { healthy = original })

	r := gin.New()
	r.GET("/healthz", healthzHandler)

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status: got %d, want 500", w.Code)
	}
	if w.Body.String() != "unhealthy" {
		t.Errorf("body: got %q, want %q", w.Body.String(), "unhealthy")
	}
}
```

### Verify "Done when"

```sh
cd app
go test -v
# === RUN   TestRootHandler
# --- PASS: TestRootHandler (0.00s)
# === RUN   TestHealthzHealthy
# --- PASS: TestHealthzHealthy (0.00s)
# === RUN   TestHealthzFailing
# --- PASS: TestHealthzFailing (0.00s)
# PASS
# ok      gitops-vm       0.239s
```

```sh
go vet ./...
# (no output = pass)
```

Coverage is not a target. Three tests = three behaviors covered. Move on.

---

## Phase 7

**Goal.** Produce the binary Jenkins will produce: static, stripped, no CGO,
no embedded local paths. Same `gitops-api`, smaller and portable across any
AL2023 EC2 with no Go installed.

Notes on the design:

- `CGO_ENABLED=0` → no libc linkage. The binary runs on any Linux with a
  compatible kernel, no glibc version surprises on the target VM.
- `-trimpath` → removes local file paths from the binary. Cleaner for a
  portfolio binary someone might `strings` out of curiosity.
- `-s -w` (inside `-ldflags`) → strips the symbol table and DWARF debug info.
  Roughly halves binary size. No effect on runtime behavior.
- `GOOS=linux GOARCH=amd64` is explicit so cross-compiling from Windows or
  Mac produces an AL2023-ready binary. On Linux it's a no-op.

### Final build command (this goes into `Jenkinsfile.build`)

```sh
# From repo root
VERSION=$(cat app/VERSION)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=${VERSION} -X main.healthy=true" \
  -o gitops-api \
  ./app
```

Rollback-demo "broken" build is the same command with `healthy=false`:

```sh
VERSION=$(cat app/VERSION)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=${VERSION} -X main.healthy=false" \
  -o gitops-api-bad \
  ./app
```

### PowerShell equivalents (Windows host, cross-compiling for AL2023)

```powershell
$VERSION = (Get-Content app/VERSION -Raw).Trim()
$env:CGO_ENABLED = "0"
$env:GOOS         = "linux"
$env:GOARCH       = "amd64"

go build `
  -trimpath `
  -ldflags "-s -w -X main.version=$VERSION -X main.healthy=true" `
  -o gitops-api `
  ./app

# Clean up env vars so later builds aren't surprised
Remove-Item Env:CGO_ENABLED, Env:GOOS, Env:GOARCH
```

The output `gitops-api` (no `.exe`) is a Linux ELF binary — it will not run
on Windows. That is correct; Jenkins will scp it to the AL2023 app VM where
it does run.

### Verify "Done when"

**Check A — binary is statically linked (run on Linux / WSL):**

```sh
file ./gitops-api
# gitops-api: ELF 64-bit LSB executable, x86-64, ... statically linked, ...
```

If you see `dynamically linked` here, `CGO_ENABLED=0` did not take effect.

**Check B — binary is reasonably small:**

```sh
ls -lh gitops-api
# -rwxr-xr-x  1 user  group   ~10M  ...  gitops-api
```

Should be under ~15 MB. The `-s -w` flags account for most of the savings.

**Check C — no local paths leak into the binary:**

```sh
strings gitops-api | grep -E "/home|/Users|OneDrive" | head
# (no output = pass)
```

Without `-trimpath`, you would see your build host's filesystem layout in
this output — embarrassing for a public repo.

**Check D — runs on a fresh AL2023 EC2 with no Go installed:**

This is the real test, deferred until M1. For now, run locally on Linux/WSL:

```sh
./gitops-api
# [GIN-debug] Listening and serving HTTP on :8080
```

```sh
curl http://localhost:8080/
# {"app":"VM GitOps Practices","version":"0.1.0"}

curl http://localhost:8080/healthz
# ok
```

### Notes / adjustments

_(record anything you had to change.)_

### Phase 7 → done

The `app/` directory is complete. From here, the only reason to touch `app/`
is to bump `app/VERSION`. Remaining work (M1 onward) is Ansible, Terraform,
nginx, Jenkins — `infra/`, `ansible/`, `deploy/`, `jenkins/`.

---
