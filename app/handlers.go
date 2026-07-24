package main

import (
	"encoding/json"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"
)

// Set via -ldflags at build time; see Dockerfile.
var (
	gitSHA    = "dev"
	imageTag  = "dev"
	buildTime = "unknown"
)

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok"))
}

func buildHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{
		"gitSha":    gitSHA,
		"imageTag":  imageTag,
		"buildTime": buildTime,
		"goVersion": runtime.Version(),
	})
}

func runtimeHandler(meta taskMetadata, hostname string, startTime time.Time, requestCount *int64) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"taskId":           meta.TaskID,
			"availabilityZone": meta.AvailabilityZone,
			"hostname":         hostname,
			"uptimeSeconds":    int(time.Since(startTime).Seconds()),
			"requestCount":     atomic.LoadInt64(requestCount),
		})
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}
