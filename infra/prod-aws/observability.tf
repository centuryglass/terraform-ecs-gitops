#----------------------------------------------------------
# Logging and alerts
#----------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = format("/ecs/waypoint%s", local.instance_suffix)
  retention_in_days = 14
}

resource "aws_sns_topic" "alerts" {
  name = format("waypoint-alerts%s", local.instance_suffix)
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Gated by var.backend_enabled — it monitors the ALB target group, which only
# exists while the backend tier is up.
resource "aws_cloudwatch_metric_alarm" "target_unhealthy" {
  count               = var.backend_enabled ? 1 : 0
  alarm_name          = format("waypoint-target-unhealthy%s", local.instance_suffix)
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2 # ~2 min of unhealthy before alerting, avoids noise on brief deploys
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # no data usually means something's badly wrong too

  dimensions = {
    TargetGroup  = aws_lb_target_group.app[0].arn_suffix
    LoadBalancer = aws_lb.app[0].arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # also notify on recovery
}

#----------------------------------------------------------
# Cost guardrail
#----------------------------------------------------------

# Sized for a portfolio piece that sits at <$1/mo at rest, not a live
# deployment. The one expensive mistake now is leaving the on-demand backend
# (ALB + ECS + VPC endpoints, ~$69/mo ≈ ~$2.30/day) applied after a demo, so
# the thresholds are tuned to catch that fast. FORECASTED matters most here:
# it reacts to run-rate within ~a day, whereas monthly ACTUAL spend resets on
# the 1st and accumulates slowly.
resource "aws_budgets_budget" "monthly_cap" {
  name         = format("waypoint-monthly-cap%s", local.instance_suffix)
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # ~$2: at-rest is <$1, so this means something's running that shouldn't be.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 40
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Run-rate says we'll blow the $5 cap — trips within ~a day of a forgotten backend.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  # Hard signal: the month has actually exceeded the cap.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Dedicated "backend left running" tripwire. At-rest daily cost is ~$0.02; a
# running backend is ~$2.30/day, so a $1/day cap fires within a day of a
# forgotten teardown — the fastest cheap signal AWS Budgets can give. Cost
# budgets are free up to two, so this adds no charge.
resource "aws_budgets_budget" "daily_tripwire" {
  name         = format("waypoint-daily-tripwire%s", local.instance_suffix)
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "DAILY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
