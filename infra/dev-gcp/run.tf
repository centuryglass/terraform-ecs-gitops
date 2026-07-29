#----------------------------------------------------------
# Artifact Registry (container images)
#----------------------------------------------------------

resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = "waypoint-imgs"
  format        = "DOCKER"
  description   = "Container images for the waypoint live-demo app"

  # Bound storage cost (the one non-zero line in this stack): keep the 5 most
  # recent versions, prune untagged layers after a week.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-5"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  depends_on = [google_project_service.services]
}

#----------------------------------------------------------
# Cloud Run service (scale-to-zero backend)
#----------------------------------------------------------

resource "google_cloud_run_v2_service" "app" {
  name     = "waypoint"
  location = var.region

  # Dev/demo env: keep teardown frictionless.
  deletion_protection = false

  # Public ingress: Firebase Hosting proxies from Google's edge (external), and
  # we want to curl the service directly for smoke tests.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      min_instance_count = 0 # scale to zero: $0 at rest
      max_instance_count = 2
    }

    containers {
      image = var.image

      ports {
        container_port = var.container_port
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  depends_on = [google_project_service.services]
}

#----------------------------------------------------------
# Public invoker
# Firebase Hosting rewrites can only reach the service if it allows
# unauthenticated invocation. Acceptable here, it only serves harmless
# build/runtime JSON. (No org policy blocks allUsers on a personal project.)
#----------------------------------------------------------

resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
