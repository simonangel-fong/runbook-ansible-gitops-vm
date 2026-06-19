// app/handlers_test.go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func TestRootHandler(t *testing.T) {
	// get version
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

func TestMetricsEndpoint(t *testing.T) {
	initMetrics()

	r := gin.New()
	r.Use(metricsMiddleware())
	r.GET("/healthz", healthzHandler)
	r.GET("/metrics", metricsHandler)

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	w = httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", w.Code)
	}
	body := w.Body.String()
	for _, want := range []string{
		"gitops_api_requests_total",
		"gitops_api_request_duration_seconds",
		"gitops_api_info",
		"gitops_api_healthy",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics body missing %q", want)
		}
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
