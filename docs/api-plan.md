# API Build Plan

| Field         | Value                                                                       |
| ------------- | --------------------------------------------------------------------------- |
| Status        | Draft v1                                                                    |
| Last updated  | 2026-06-15                                                                  |
| Parent docs   | [prd.md](prd.md) (FR-1 through FR-5a, NFR-1) · [plan.md](plan.md)           |
| Scope         | Just the Go RESTful API in `app/`. Nothing about Ansible / Jenkins / nginx. |

## 0. What we are building

A tiny Go HTTP service, built with `gin`, that:

- Serves `GET /` returning `{"app":"VM GitOps Practices","version":"<v>"}`.
- Serves `GET /healthz` returning `200 ok` when healthy, `500` when the
  baked-in failure flag is `true`.
- Has its `version` string baked in at build time via `-ldflags`.
- Has a `healthy` boolean baked in at build time via `-ldflags`. Default
  `true`; a `healthy=false` build is the rollback-demo "broken" build.
- Listens on `:8080`.
- Shuts down gracefully on `SIGTERM` (10s drain).
- Uses `gin.Default()` so every request logs one line to stdout.

That is the entire surface area. Resist adding anything else - the API is
deliberately trivial so the GitOps machinery around it is the interesting
part. (See [prd.md](prd.md) §3.3 Non-goals.)

## 1. Target Layout (final state)

```
app/
├── VERSION              # plain text, e.g. "0.1.0" - human-edited
├── go.mod
├── go.sum
├── main.go              # entry point, server setup, graceful shutdown
├── handlers.go          # root + healthz handlers
└── handlers_test.go     # one httptest test per handler
```

Five files. If we end up with more, we have probably over-engineered.

## 2. Build Command (final state)

This is what Jenkins will run (PRD FR-3, FR-4). Worth knowing up front so the
code is structured for it:

```bash
VERSION=$(cat app/VERSION)
go build \
  -ldflags "-X main.version=${VERSION} -X main.healthy=true" \
  -o gitops-api \
  ./app
```

The "broken" rollback-demo build is the same command with `healthy=false`.

## 3. Phases

Each phase produces something runnable and testable on its own. Don't move on
until the "Done when" check passes.

### Phase 1 - Scaffold and "hello world"

**Goal.** Project compiles and serves a hardcoded response on `:8080`.

Work:

1. `cd app && go mod init github.com/simonangel-fong/gitops-vm/app`.
2. `go get github.com/gin-gonic/gin`.
3. Write a minimal `main.go` that calls `gin.Default()`, registers `GET /`
   returning a hardcoded `{"app":"VM GitOps Practices","version":"dev"}`,
   and calls `r.Run(":8080")`.
4. `echo 0.1.0 > app/VERSION` - placeholder for now, not yet wired in.

Done when:

- `go run ./app` starts the server, logs "Listening and serving HTTP on :8080".
- `curl localhost:8080/` returns the JSON with `version: "dev"`.

### Phase 2 - Handlers in their own file, both endpoints

**Goal.** `/` and `/healthz` work; handler logic separated from server setup.

Work:

1. Move handler functions from `main.go` into a new `handlers.go`.
2. Add a `GET /healthz` handler returning `200` with body `ok` (plain text, not
   JSON - matches PRD FR-2's `200 ok`).
3. `main.go` shrinks to: load gin, register routes, run. Nothing else yet.

Done when:

- `curl localhost:8080/` → JSON with version (still "dev").
- `curl localhost:8080/healthz` → `200 ok`.
- `curl -i localhost:8080/healthz` shows `Content-Type: text/plain`.

### Phase 3 - Version injected via `-ldflags`

**Goal.** The version in `GET /` comes from `app/VERSION`, set at build time.

Work:

1. In `main.go`, declare `var version = "dev"` at package level. The string
   literal `"dev"` is the default if no `-ldflags` value is passed (so
   `go run` still works without the build command).
2. Update the root handler to read this `version` variable.
3. Build with the real command (§2 above), confirm the response changes.

Done when:

- `go run ./app` → `/` returns `version: "dev"` (unflagged default).
- `go build -ldflags "-X main.version=0.1.0" -o gitops-api ./app && ./gitops-api`
  → `/` returns `version: "0.1.0"`.
- A version mismatch (running an old binary after editing `VERSION`) does
  NOT change the response - confirming the version is baked into the binary,
  not read at runtime.

### Phase 4 - Failure-injection flag via `-ldflags`

**Goal.** Baked-in `healthy=false` build returns `500` on `/healthz`.

Work:

1. In `main.go`, declare `var healthy = "true"` (string, because
   `-ldflags -X` can only set string vars). The default `"true"` matches the
   natural state - no mental flip when reading either the variable or the
   build command.
2. In the `/healthz` handler, parse `healthy` once (at package init or
   per-request - either is fine for this scale) and return `500` with body
   `unhealthy` if it is not `"true"`.
3. Build two binaries: one with the default, one with `healthy=false`.

Done when:

- Default build: `curl -i localhost:8080/healthz` → `200 ok`.
- Failure build: `curl -i localhost:8080/healthz` → `500 unhealthy`. **AND**
  `/` still returns the version (the flag affects only `/healthz`).
- The flag is not readable from outside - there is no debug endpoint that
  reveals its value. (It's a *test hook*, not a *feature*.)

### Phase 5 - Graceful shutdown

**Goal.** `SIGTERM` triggers a 10s drain instead of an instant kill. (PRD
NFR-1 part b.)

Work:

1. Replace `r.Run(":8080")` with an explicit `&http.Server{Handler: r}` and a
   goroutine that calls `srv.ListenAndServe()`.
2. In the main goroutine, `signal.Notify` on `SIGINT` and `SIGTERM`. Wait.
3. On signal: log "shutting down", call `srv.Shutdown(ctx)` with a 10s
   context, exit.

Done when:

- Start the server. In another terminal, `curl localhost:8080/healthz` works.
- Send `SIGTERM` (`kill -TERM <pid>`). Log shows "shutting down". Server
  exits within 10s. New connections refused (`curl` gets connection refused);
  in-flight connections complete.
- Manual drain check: hit a synthetic slow request and send `SIGTERM`
  mid-flight. The slow request completes. (For this you can add a temporary
  `/sleep` route locally - delete before commit.)

### Phase 6 - Tests (minimal, per PRD decision)

**Goal.** One `httptest` test per handler. Confirms the contract holds; runs
in milliseconds.

Work:

1. `handlers_test.go`:
   - `TestRootHandler` - builds a `gin` engine, registers the root route,
     uses `httptest.NewRecorder`, asserts status 200 and JSON body shape.
     Sets the package-level `version` to a known value in the test.
   - `TestHealthzHealthy` - `healthy="true"`, expect 200 + `ok`.
   - `TestHealthzFailing` - `healthy="false"`, expect 500 + `unhealthy`.
2. Run `go test ./app -v`.

Done when:

- `go test ./app` → 3 tests pass.
- `go vet ./app` → no warnings.
- Coverage is not a target; do not chase it. Three tests = three behaviors
  covered. Move on.

### Phase 7 - Build hardening for the Jenkins pipeline

**Goal.** The binary is what Jenkins expects: static, stripped, no CGO.

Work:

1. Set `CGO_ENABLED=0` in the build command (static binary, no glibc surprise
   on the target VM).
2. Add `-trimpath` (removes local file paths from binary - cleaner for a
   portfolio binary someone might `strings` out of curiosity).
3. Add `-s -w` to `-ldflags` (strips debug info; halves binary size).
4. Final build command (this is what goes in `Jenkinsfile.build`):

```bash
VERSION=$(cat app/VERSION)
CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=${VERSION} -X main.healthy=true" \
  -o gitops-api \
  ./app
```

Done when:

- `file ./gitops-api` reports a statically linked binary.
- `./gitops-api` runs on a fresh AL2023 EC2 instance with no Go installed.
- Binary size is under ~15 MB.

## 4. What we are NOT doing (to keep scope honest)

These would be normal additions to a "serious" service but are deliberately
out of scope for v1. Calling them out so they don't sneak in:

- **No config file / no env-var config.** Everything is build-time.
- **No `/metrics`.** Prometheus is v2 (PRD §12).
- **No request ID middleware.** `gin.Default()`'s logger is enough for the
  demo.
- **No JSON-structured logging.** gin's default text logger is fine.
- **No `/version` endpoint.** `GET /` already exposes the version.
- **No DB, no auth, no rate limiting.** The service is stateless.
- **No Dockerfile.** Whole project is anti-Docker for the app.
- **No graceful shutdown drain longer than 10s.** Long-running connections
  don't exist here; 10s is generous.

## 5. Integration with the larger plan

After Phase 7 is done, the API is ready for the rest of the project:

- **Milestone M1** (PRD §9 / plan.md Phase A) needs the binary to run on an
  app VM under `systemd`. That work happens in `ansible/`, not in `app/`.
- **Milestone M3** (PRD §9 / plan.md Phase C) is wiring Phase 7's build
  command into `jenkins/Jenkinsfile.build`.
- **Milestone M6** (PRD §9 / plan.md Phase F) is when the `healthy=false`
  build matters - for the rollback demo. The API code itself is already
  done at that point.

So this whole document is the M1-prerequisite work: get the binary right
*once*, then never come back to `app/` except to bump `VERSION`.

## 6. Suggested order of operations

If you want to do this in one session:

```
Phase 1  → ~15 min   (mod init, gin hello world)
Phase 2  → ~10 min   (split handlers, add /healthz)
Phase 3  → ~10 min   (ldflags version)
Phase 4  → ~15 min   (ldflags healthy)
Phase 5  → ~20 min   (graceful shutdown)
Phase 6  → ~20 min   (3 tests)
Phase 7  → ~10 min   (build flags, verify on EC2 later)
─────────────────
Total    → ~100 min
```

Commit after each phase. Seven commits with messages like "phase 3: bake
version via ldflags" make the API's history readable in `git log`, which is
itself a portfolio signal.
