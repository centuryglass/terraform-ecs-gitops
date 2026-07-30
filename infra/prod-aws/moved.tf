# One-time state migration for the backend_enabled refactor.
#
# These resources were previously unconditional and already exist in state at
# their un-indexed addresses (aws_lb.app, ...). Giving them `count` moves them to
# `...[0]`. Without these `moved` blocks Terraform would plan destroy+recreate;
# with them it just re-tracks the existing objects at the new address.
#
# Note on the first apply after this change:
#   - With backend_enabled = false (the default), the [0] instances have count 0,
#     so Terraform migrates the addresses and then DESTROYS them — i.e. the
#     currently-running backend is torn down into the dormant ~$0/mo state. That
#     is the intended outcome; flip backend_enabled = true to bring it back.
#   - If you'd rather keep the backend running through the refactor, set
#     backend_enabled = true before applying and these blocks migrate it in place
#     with no churn.
#
# Safe to delete once this has been applied on all live states.

moved {
  from = aws_vpc_endpoint.ecr_api
  to   = aws_vpc_endpoint.ecr_api[0]
}

moved {
  from = aws_vpc_endpoint.ecr_dkr
  to   = aws_vpc_endpoint.ecr_dkr[0]
}

moved {
  from = aws_vpc_endpoint.logs
  to   = aws_vpc_endpoint.logs[0]
}

moved {
  from = aws_lb.app
  to   = aws_lb.app[0]
}

moved {
  from = aws_lb_target_group.app
  to   = aws_lb_target_group.app[0]
}

moved {
  from = aws_lb_listener.http
  to   = aws_lb_listener.http[0]
}

moved {
  from = aws_internet_gateway.custom
  to   = aws_internet_gateway.custom[0]
}

moved {
  from = aws_cloudfront_vpc_origin.alb
  to   = aws_cloudfront_vpc_origin.alb[0]
}

moved {
  from = aws_ecs_service.app
  to   = aws_ecs_service.app[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.target_unhealthy
  to   = aws_cloudwatch_metric_alarm.target_unhealthy[0]
}
