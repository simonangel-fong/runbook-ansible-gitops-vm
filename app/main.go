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

	// goroutine
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
