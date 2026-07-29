terraform {
  backend "s3" {
    bucket       = "waypoint-tfstate-905772075871-us-east-1"
    key          = "waypoint/live/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
