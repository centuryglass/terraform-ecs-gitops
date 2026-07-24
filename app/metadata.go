package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"time"
)

type taskMetadata struct {
	TaskID           string
	AvailabilityZone string
}

// fetchTaskMetadata queries the ECS task metadata endpoint (injected by
// Fargate as $ECS_CONTAINER_METADATA_URI_V4) once at startup — task identity
// is fixed for the life of the task, so there's nothing to gain from
// re-fetching per request. Returns a zero-value taskMetadata rather than an
// error when the env var is absent or the fetch fails, so the container
// still runs under a plain `docker run` or `go run` locally.
func fetchTaskMetadata() taskMetadata {
	base := os.Getenv("ECS_CONTAINER_METADATA_URI_V4")
	if base == "" {
		return taskMetadata{}
	}

	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(base + "/task")
	if err != nil {
		return taskMetadata{}
	}
	defer resp.Body.Close()

	var body struct {
		TaskARN          string `json:"TaskARN"`
		AvailabilityZone string `json:"AvailabilityZone"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return taskMetadata{}
	}

	parts := strings.Split(body.TaskARN, "/")
	taskID := parts[len(parts)-1]
	if len(taskID) > 8 {
		taskID = taskID[:8]
	}

	return taskMetadata{TaskID: taskID, AvailabilityZone: body.AvailabilityZone}
}
