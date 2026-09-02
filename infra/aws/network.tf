terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "project_name" {
  description = "Project name used in resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (for NAT/egress components)."
  type        = list(string)
  default     = ["10.20.0.0/20", "10.20.16.0/20"]
}

variable "private_app_subnet_cidrs" {
  description = "Private subnet CIDRs for ECS/Fargate tasks."
  type        = list(string)
  default     = ["10.20.32.0/20", "10.20.48.0/20"]
}

variable "private_data_subnet_cidrs" {
  description = "Private subnet CIDRs for data services (DocumentDB)."
  type        = list(string)
  default     = ["10.20.64.0/20", "10.20.80.0/20"]
}

variable "private_mq_subnet_cidrs" {
  description = "Private subnet CIDRs for messaging services (Amazon MQ RabbitMQ)."
  type        = list(string)
  default     = ["10.20.96.0/20", "10.20.112.0/20"]
}

variable "alb_security_group_id" {
  description = "Optional ALB security group ID allowed to reach ECS tasks."
  type        = string
  default     = null
}

variable "ecs_container_port" {
  description = "Primary container port exposed by ECS tasks."
  type        = number
  default     = 8080
}

variable "cloud_map_namespace_name" {
  description = "Private DNS namespace name for AWS Cloud Map service discovery."
  type        = string
  default     = "service.local"
}

variable "enable_mq_management_ui" {
  description = "Allow ECS tasks to access RabbitMQ management UI port (15672)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "private_app" {
  count = length(var.private_app_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_app_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-${count.index + 1}"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_data" {
  count = length(var.private_data_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_data_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-data-${count.index + 1}"
    Tier = "private-data"
  })
}

resource "aws_subnet" "private_mq" {
  count = length(var.private_mq_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_mq_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-mq-${count.index + 1}"
    Tier = "private-mq"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.igw]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip"
  })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat"
  })
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-rt"
  })
}

resource "aws_route_table_association" "private_app" {
  count = length(aws_subnet.private_app)

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-data-rt"
  })
}

resource "aws_route_table_association" "private_data" {
  count = length(aws_subnet.private_data)

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

resource "aws_route_table" "private_mq" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-mq-rt"
  })
}

resource "aws_route_table_association" "private_mq" {
  count = length(aws_subnet.private_mq)

  subnet_id      = aws_subnet.private_mq[count.index].id
  route_table_id = aws_route_table.private_mq.id
}

resource "aws_service_discovery_private_dns_namespace" "cloud_map" {
  name = var.cloud_map_namespace_name
  vpc  = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloud-map-ns"
  })
}

resource "aws_docdb_subnet_group" "documentdb" {
  name       = "${local.name_prefix}-docdb-subnet-group"
  subnet_ids = aws_subnet.private_data[*].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-docdb-subnet-group"
  })
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "Security group for ECS Fargate tasks"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecs-tasks-sg"
  })
}

resource "aws_security_group_rule" "ecs_from_alb" {
  count = var.alb_security_group_id == null ? 0 : 1

  type                     = "ingress"
  from_port                = var.ecs_container_port
  to_port                  = var.ecs_container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_tasks.id
  source_security_group_id = var.alb_security_group_id
  description              = "Allow inbound app traffic from ALB"
}

resource "aws_security_group" "documentdb" {
  name        = "${local.name_prefix}-docdb-sg"
  description = "Security group for Amazon DocumentDB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-docdb-sg"
  })
}

resource "aws_security_group_rule" "documentdb_from_ecs" {
  type                     = "ingress"
  from_port                = 27017
  to_port                  = 27017
  protocol                 = "tcp"
  security_group_id        = aws_security_group.documentdb.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  description              = "Allow ECS tasks to connect to DocumentDB"
}

resource "aws_security_group_rule" "documentdb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.documentdb.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow outbound traffic from DocumentDB SG"
}

resource "aws_security_group" "rabbitmq" {
  name        = "${local.name_prefix}-rabbitmq-sg"
  description = "Security group for Amazon MQ RabbitMQ"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rabbitmq-sg"
  })
}

resource "aws_security_group_rule" "rabbitmq_amqps_from_ecs" {
  type                     = "ingress"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rabbitmq.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  description              = "Allow ECS tasks to connect to RabbitMQ over TLS"
}

resource "aws_security_group_rule" "rabbitmq_amqp_from_ecs" {
  type                     = "ingress"
  from_port                = 5672
  to_port                  = 5672
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rabbitmq.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  description              = "Allow ECS tasks to connect to RabbitMQ"
}

resource "aws_security_group_rule" "rabbitmq_mgmt_from_ecs" {
  count = var.enable_mq_management_ui ? 1 : 0

  type                     = "ingress"
  from_port                = 15672
  to_port                  = 15672
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rabbitmq.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  description              = "Allow ECS tasks to access RabbitMQ management UI"
}

resource "aws_security_group_rule" "rabbitmq_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.rabbitmq.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow outbound traffic from RabbitMQ SG"
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private subnet IDs for ECS tasks"
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "Private subnet IDs for DocumentDB"
  value       = aws_subnet.private_data[*].id
}

output "private_mq_subnet_ids" {
  description = "Private subnet IDs for Amazon MQ"
  value       = aws_subnet.private_mq[*].id
}

output "ecs_tasks_security_group_id" {
  description = "Security group ID for ECS tasks"
  value       = aws_security_group.ecs_tasks.id
}

output "documentdb_security_group_id" {
  description = "Security group ID for DocumentDB"
  value       = aws_security_group.documentdb.id
}

output "rabbitmq_security_group_id" {
  description = "Security group ID for Amazon MQ RabbitMQ"
  value       = aws_security_group.rabbitmq.id
}

output "documentdb_subnet_group_name" {
  description = "DocumentDB subnet group name"
  value       = aws_docdb_subnet_group.documentdb.name
}

output "cloud_map_namespace_id" {
  description = "Cloud Map private DNS namespace ID"
  value       = aws_service_discovery_private_dns_namespace.cloud_map.id
}