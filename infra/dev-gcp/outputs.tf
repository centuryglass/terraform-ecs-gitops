output "cloud_run_url" {
  description = "Direct Cloud Run URL. curl this to smoke-test the backend before Firebase Hosting is wired up."
  value       = google_cloud_run_v2_service.app.uri
}

output "artifact_registry_repo" {
  description = "Push images here. Auth Docker once for the registry host with: gcloud auth configure-docker <region>-docker.pkg.dev"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "firebase_hosting_url" {
  description = "Default *.web.app URL for the live demo. Phase 3 deploys the static frontend here with an /api/** rewrite to Cloud Run."
  value       = "https://${var.project_id}.web.app"
}

#----------------------------------------------------------
# CI wiring — set these on the GitHub `dev` Environment (Phase 4b).
#----------------------------------------------------------

output "wif_provider" {
  description = "Full WIF provider resource name. Set as the workload_identity_provider input to google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "sa_push_email" {
  description = "Service account for the build-push workflow."
  value       = google_service_account.gha_push.email
}

output "sa_plan_email" {
  description = "Service account for the terraform-plan workflow."
  value       = google_service_account.gha_plan.email
}

output "sa_apply_email" {
  description = "Service account for the terraform-apply workflow."
  value       = google_service_account.gha_apply.email
}

output "sa_frontend_email" {
  description = "Service account for the frontend-deploy workflow."
  value       = google_service_account.gha_frontend.email
}
