#----------------------------------------------------------
# Container registry + cluster
#----------------------------------------------------------

resource "aws_ecr_repository" "container_registry" {
  name                 = format("waypoint-build-imgs%s", local.instance_suffix)
  image_tag_mutability = "IMMUTABLE"
}

resource "aws_ecs_cluster" "container_cluster" {
  name = format("waypoint-ecs%s", local.instance_suffix)
}

#----------------------------------------------------------
# ECS task execution role
# (pulls from ECR, writes to CloudWatch Logs — nothing else)
#----------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = format("waypoint-ecs-task-execution%s", local.instance_suffix)
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#----------------------------------------------------------
# ECS task definition + service
#----------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = format("waypoint%s", local.instance_suffix)
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = format("waypoint%s", local.instance_suffix)
      image     = format("%s:%s", aws_ecr_repository.container_registry.repository_url, var.image_tag)
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "PORT"
          value = tostring(var.container_port)
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = format("waypoint%s", local.instance_suffix)
        }
      }
    }
  ])
}

# Gated by var.backend_enabled — this is the running Fargate task (~$9/mo). The
# task definition above stays registered always (it's free); only the service
# that actually runs a task toggles.
resource "aws_ecs_service" "app" {
  count           = var.backend_enabled ? 1 : 0
  name            = format("waypoint-service%s", local.instance_suffix)
  cluster         = aws_ecs_cluster.container_cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app[0].arn
    container_name   = format("waypoint%s", local.instance_suffix)
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]
}
