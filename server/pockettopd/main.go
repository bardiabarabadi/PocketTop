// pockettopd is the server-side agent for PocketTop. It exposes HTTPS
// endpoints for /health, /version, /history, and /processes/{pid}/kill.
//
// All metrics are read from /proc and /sys on Linux. On non-Linux builds
// (e.g. a dev build on macOS for compile-checking) the readers return
// stub data so the binary still builds and runs.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/bardiabarabadi/PocketTop/server/pockettopd/metrics"
)

const version = "1.0.0"

func main() {
	certPath := flag.String("cert", "/opt/pockettop/certs/cert.pem", "path to TLS certificate (PEM)")
	keyPath := flag.String("key", "/opt/pockettop/certs/key.pem", "path to TLS private key (PEM)")
	apiKeyFile := flag.String("api-key-file", "/opt/pockettop/.api_key", "path to API key file")
	port := flag.Int("port", 443, "TCP port to listen on")
	bind := flag.String("bind", "0.0.0.0", "bind address")
	flag.Parse()

	// Start the metrics sampler goroutine. It refreshes CPU, disk, net,
	// and per-process CPU snapshots every ~500ms so handlers read cached
	// deltas instead of sleeping inside the request path.
	sampler := metrics.NewSampler()
	sampler.Start()

	auth := newAuthMiddleware(*apiKeyFile)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", handleHealth)
	mux.HandleFunc("GET /version", handleVersion)
	mux.Handle("GET /history", auth.wrap(handleHistory(sampler)))
	mux.Handle("POST /processes/{pid}/kill", auth.wrap(handleKill))

	addr := fmt.Sprintf("%s:%d", *bind, *port)

	if _, err := os.Stat(*certPath); err != nil {
		log.Fatalf("cert file not found at %s: %v", *certPath, err)
	}
	if _, err := os.Stat(*keyPath); err != nil {
		log.Fatalf("key file not found at %s: %v", *keyPath, err)
	}

	log.Printf("pockettopd %s listening on https://%s", version, addr)
	server := &http.Server{
		Addr:    addr,
		Handler: gzipMiddleware(mux),
	}
	if err := server.ListenAndServeTLS(*certPath, *keyPath); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}
