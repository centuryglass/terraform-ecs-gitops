#----------------------------------------------------------
# Cost guardrail — GCP-side mirror of the AWS budget tripwire.
# This stack should sit at ~$0; a $1 cap with early alerts catches anything
# unexpected fast (the FORECASTED rule reacts to run-rate within ~a day).
#----------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  display_name = "waypoint-live budget alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.services]
}

resource "google_billing_budget" "monthly_cap" {
  billing_account = var.billing_account
  display_name    = "waypoint-live-monthly-cap"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "1"
    }
  }

  threshold_rules {
    threshold_percent = 0.5 # $0.50 actual — something's running that shouldn't be
  }
  threshold_rules {
    threshold_percent = 1.0 # $1 actual — hard signal
  }
  threshold_rules {
    threshold_percent = 1.0 # forecasted to hit $1 — fastest early warning
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.services]
}
