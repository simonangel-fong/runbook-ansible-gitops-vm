// app/handlers.go
package main

import (
	"os"

	"github.com/gin-gonic/gin"
)

// handler for /
func rootHandler(c *gin.Context) {
	host, _ := os.Hostname()
	c.JSON(200, gin.H{
		"app":     "VM GitOps Practices",
		"version": version,
		"host":    host,
	})
}

// handler for /healthy
func healthzHandler(c *gin.Context) {
	if healthy != "true" {
		c.String(500, "unhealthy")
		return
	}
	c.String(200, "ok")
}
