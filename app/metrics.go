// app/metrics.go
package main

import (
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "gitops_api_requests_total",
			Help: "Total HTTP requests handled, labelled by matched route, response code, and host.",
		},
		[]string{"path", "code", "host"},
	)

	requestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "gitops_api_request_duration_seconds",
			Help:    "HTTP request duration in seconds, labelled by matched route and host.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"path", "host"},
	)

	apiInfo = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "gitops_api_info",
			Help: "Build info - always 1, labels carry version and host.",
		},
		[]string{"version", "host"},
	)

	apiHealthy = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "gitops_api_healthy",
			Help: "1 if the instance reports healthy, 0 otherwise.",
		},
		[]string{"host"},
	)
)

func init() {
	prometheus.MustRegister(requestsTotal, requestDuration, apiInfo, apiHealthy)
}

// initMetrics seeds the gauges with their startup values.
func initMetrics() {
	host, _ := os.Hostname()
	apiInfo.WithLabelValues(version, host).Set(1)
	if healthy == "true" {
		apiHealthy.WithLabelValues(host).Set(1)
	} else {
		apiHealthy.WithLabelValues(host).Set(0)
	}
}

func metricsMiddleware() gin.HandlerFunc {
	host, _ := os.Hostname()
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()

		// FullPath() returns the matched route template
		path := c.FullPath()
		if path == "" {
			path = "unknown"
		}
		code := strconv.Itoa(c.Writer.Status())

		requestsTotal.WithLabelValues(path, code, host).Inc()
		requestDuration.WithLabelValues(path, host).Observe(time.Since(start).Seconds())
	}
}

func metricsHandler(c *gin.Context) {
	promhttp.Handler().ServeHTTP(c.Writer, c.Request)
}
