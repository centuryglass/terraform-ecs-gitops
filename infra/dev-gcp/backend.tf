terraform {
  backend "gcs" {
    bucket = "waypoint-live-0857-tfstate"
    prefix = "waypoint/dev-gcp"
  }
}
