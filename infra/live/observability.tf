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

resource "aws_cloudwatch_metric_alarm" "target_unhealthy" {
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
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # also notify on recovery
}

#----------------------------------------------------------
# Cost guardrail
#----------------------------------------------------------

resource "aws_budgets_budget" "monthly_cap" {
  name         = format("waypoint-monthly-cap%s", local.instance_suffix)
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 30
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
