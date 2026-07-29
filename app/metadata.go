package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// instanceField is one labeled runtime fact shown under "Runtime" on the page.
type instanceField struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

// runtimeMetadata is the platform identity of the running container, resolved
// once at startup (identity is fixed for the life of the process). Which fields
// are present depends on where we're running: AWS ECS Fargate, GCP Cloud Run,
// or a plain local process.
type runtimeMetadata struct {
	Platform string          `json:"platform"`
	Fields   []instanceField `json:"fields"`
}

// fetchRuntimeMetadata detects the hosting platform from the environment markers
// each provider injects, then gathers the identity facts that are actually
// useful there. It degrades to a bare "Local" hostname when neither provider's
// markers are present, so the container still runs under `docker run`/`go run`.
func fetchRuntimeMetadata() runtimeMetadata {
	switch {
	case os.Getenv("K_SERVICE") != "": // Cloud Run always sets this.
		return gcpCloudRunMetadata()
	case os.Getenv("ECS_CONTAINER_METADATA_URI_V4") != "": // Fargate injects this.
		return awsFargateMetadata()
	default:
		return localMetadata()
	}
}

func localMetadata() runtimeMetadata {
	hostname, _ := os.Hostname()
	return runtimeMetadata{
		Platform: "Local",
		Fields:   []instanceField{{Label: "Hostname", Value: hostname}},
	}
}

// awsFargateMetadata reads task identity from the ECS task metadata endpoint.
// Falls back to just the hostname if the endpoint can't be reached.
func awsFargateMetadata() runtimeMetadata {
	hostname, _ := os.Hostname()
	fields := []instanceField{}

	base := os.Getenv("ECS_CONTAINER_METADATA_URI_V4")
	var task struct {
		TaskARN          string `json:"TaskARN"`
		AvailabilityZone string `json:"AvailabilityZone"`
	}
	if err := getJSON(base+"/task", nil, &task); err == nil {
		taskID := task.TaskARN
		if i := strings.LastIndex(taskID, "/"); i >= 0 {
			taskID = taskID[i+1:]
		}
		if len(taskID) > 8 {
			taskID = taskID[:8]
		}
		fields = append(fields,
			instanceField{Label: "Task ID", Value: taskID},
			instanceField{Label: "Availability zone", Value: task.AvailabilityZone},
		)
	}
	fields = append(fields, instanceField{Label: "Hostname", Value: hostname})

	return runtimeMetadata{Platform: "AWS ECS Fargate", Fields: fields}
}

// gcpCloudRunMetadata reads service/revision from the env vars Cloud Run always
// sets, then best-effort augments with region + instance ID from the GCP
// metadata server (which requires the Metadata-Flavor: Google header). Each
// metadata-server field is included only if its lookup succeeds.
func gcpCloudRunMetadata() runtimeMetadata {
	fields := []instanceField{
		{Label: "Service", Value: os.Getenv("K_SERVICE")},
		{Label: "Revision", Value: os.Getenv("K_REVISION")},
	}

	const mdBase = "http://metadata.google.internal/computeMetadata/v1/"
	hdr := map[string]string{"Metadata-Flavor": "Google"}

	if region, err := getText(mdBase+"instance/region", hdr); err == nil {
		// Returns projects/PROJECT_NUMBER/regions/REGION — keep the last segment.
		if i := strings.LastIndex(region, "/"); i >= 0 {
			region = region[i+1:]
		}
		fields = append(fields, instanceField{Label: "Region", Value: region})
	}
	if id, err := getText(mdBase+"instance/id", hdr); err == nil {
		if len(id) > 12 {
			id = id[:12]
		}
		fields = append(fields, instanceField{Label: "Instance ID", Value: id})
	}

	return runtimeMetadata{Platform: "GCP Cloud Run", Fields: fields}
}

// metadataClient is shared by the provider metadata lookups; the short timeout
// keeps a missing/slow metadata server from stalling startup.
var metadataClient = http.Client{Timeout: 2 * time.Second}

func metadataGet(url string, headers map[string]string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := metadataClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("metadata GET %s: status %d", url, resp.StatusCode)
	}
	return resp, nil
}

func getJSON(url string, headers map[string]string, out any) error {
	resp, err := metadataGet(url, headers)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

func getText(url string, headers map[string]string) (string, error) {
	resp, err := metadataGet(url, headers)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}
