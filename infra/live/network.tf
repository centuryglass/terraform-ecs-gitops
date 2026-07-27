#----------------------------------------------------------
# Custom VPC — private subnets + VPC endpoints (no NAT)
# Standalone for now: validates ECR pull + log write from a private
# subnet before ALB/ECS actually move into it (step 3 of the plan).
#----------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "custom" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = format("waypoint-vpc%s", local.instance_suffix)
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.custom.id
  cidr_block        = cidrsubnet(aws_vpc.custom.cidr_block, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = format("waypoint-private-%s%s", count.index, local.instance_suffix)
  }
}

# Local-only route table — no IGW, no NAT route. The S3 gateway endpoint
# association below adds the prefix-list route needed for ECR layer pulls.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.custom.id

  tags = {
    Name = format("waypoint-private-rt%s", local.instance_suffix)
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# SG for the interface endpoints. Using the VPC CIDR here rather than a
# security-group reference — SG-to-SG references only work within the
# same VPC, and the ECS task SG still lives in the default VPC at this
# point in the migration. Revisit once ECS tasks actually run in `custom`.
resource "aws_security_group" "vpc_endpoints" {
  name        = format("waypoint-vpce-sg%s", local.instance_suffix)
  description = "Allow HTTPS from within the custom VPC to interface endpoints"
  vpc_id      = aws_vpc.custom.id
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront VPC origins"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.ecs_service.id
}

# Interface endpoints: ECR API, ECR Docker registry, CloudWatch Logs
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-ecr-api%s", local.instance_suffix) }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-ecr-dkr%s", local.instance_suffix) }
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.custom.id
  service_name        = "com.amazonaws.${local.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = format("waypoint-vpce-logs%s", local.instance_suffix) }
}

# Gateway endpoint: S3. Free, and required — ECR layers are stored in S3,
# so image pulls fail without this once there's no NAT Gateway route.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.custom.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = format("waypoint-vpce-s3%s", local.instance_suffix) }
}


#----------------------------------------------------------
# Security groups
#----------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = format("waypoint-alb-sg%s", local.instance_suffix)
  description = "Allow inbound HTTP from within the custom VPC" # From the CloudFront origin's prefix list
  vpc_id      = aws_vpc.custom.id
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ecs_service" {
  name        = format("waypoint-ecs-svc-sg%s", local.instance_suffix)
  description = "Allow inbound app traffic from the ALB only"
  vpc_id      = aws_vpc.custom.id
}

resource "aws_vpc_security_group_ingress_rule" "ecs_service_http" {
  security_group_id            = aws_security_group.ecs_service.id
  description                  = "App traffic from ALB"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "ecs_service_all" {
  security_group_id = aws_security_group.ecs_service.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
