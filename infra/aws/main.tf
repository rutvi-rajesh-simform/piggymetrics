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

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

############################
# Networking inputs
############################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "VPC ID for all resources"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by ECS/DocumentDB/MQ"
  type        = list(string)
}

variable "ecs_service_desired_count" {
  description = "Desired task count for ECS service"
  type        = number
  default     = 2
}

variable "ecs_task_cpu" {
  description = "Task CPU units"
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "Task memory (MiB)"
  type        = number
  default     = 1024
}

variable "container_port" {
  description = "Application container port"
  type        = number
  default     = 8080
}

variable "container_image" {
  description = "Container image URI"
  type        = string
}

variable "docdb_username" {
  description = "DocumentDB master username"
  type        = string
  default     = "docdbadmin"
}

variable "docdb_password" {
  description = "DocumentDB master password"
  type        = string
  sensitive   = true
}

variable "ses_domain" {
  description = "Domain for SES identity verification"
  type        = string
}

############################
# Security groups
############################

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "Security group for ECS tasks"
  vpc_id      = var.vpc_id

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

resource "aws_security_group" "docdb" {
  name        = "${local.name_prefix}-docdb-sg"
  description = "Security group for Amazon DocumentDB"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-docdb-sg"
  })
}

resource "aws_security_group" "mq" {
  name        = "${local.name_prefix}-mq-sg"
  description = "Security group for Amazon MQ RabbitMQ"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5671
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  ingress {
    from_port       = 15671
    to_port         = 15672
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mq-sg"
  })
}

############################
# Cloud Map
############################

resource "aws_service_discovery_private_dns_namespace" "app" {
  name        = "${local.name_prefix}.local"
  description = "Private namespace for service discovery"
  vpc         = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-namespace"
  })
}

resource "aws_service_discovery_service" "ecs" {
  name = "${local.name_prefix}-svc"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.app.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}

############################
# Amazon DocumentDB
############################

resource "aws_docdb_subnet_group" "this" {
  name       = "${local.name_prefix}-docdb-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-docdb-subnet-group"
  })
}

resource "aws_docdb_cluster_parameter_group" "this" {
  family = "docdb5.0"
  name   = "${local.name_prefix}-docdb-pg"

  parameter {
    name  = "tls"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier              = "${local.name_prefix}-docdb"
  engine                          = "docdb"
  master_username                 = var.docdb_username
  master_password                 = var.docdb_password
  db_subnet_group_name            = aws_docdb_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.docdb.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name
  skip_final_snapshot             = true
  backup_retention_period         = 7
  preferred_backup_window         = "03:00-04:00"

  tags = local.common_tags
}

resource "aws_docdb_cluster_instance" "this" {
  identifier         = "${local.name_prefix}-docdb-1"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = "db.t3.medium"

  tags = local.common_tags
}

############################
# Amazon MQ (RabbitMQ)
############################

resource "aws_mq_broker" "rabbitmq" {
  broker_name                = "${local.name_prefix}-rabbitmq"
  engine_type                = "RabbitMQ"
  engine_version             = "3.13"
  host_instance_type         = "mq.t3.micro"
  deployment_mode            = "SINGLE_INSTANCE"
  subnet_ids                 = [var.private_subnet_ids[0]]
  security_groups            = [aws_security_group.mq.id]
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  user {
    username = "appuser"
    password = var.docdb_password
  }

  logs {
    general = true
  }

  tags = local.common_tags
}

############################
# ECS Fargate
############################

resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "ecs_app_policy" {
  name = "${local.name_prefix}-ecs-app-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "docdb-elastic:ListClusters"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "mq:DescribeBroker"
        ],
        Resource = aws_mq_broker.rabbitmq.arn
      },
      {
        Effect = "Allow",
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ],
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_app_policy" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_app_policy.arn
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.ecs_task_cpu)
  memory                   = tostring(var.ecs_task_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "DOCDB_ENDPOINT"
          value = aws_docdb_cluster.this.endpoint
        },
        {
          name  = "DOCDB_PORT"
          value = "27017"
        },
        {
          name  = "RABBITMQ_ENDPOINT"
          value = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
        },
        {
          name  = "SES_REGION"
          value = data.aws_region.current.name
        },
        {
          name  = "CLOUDMAP_SERVICE_NAME"
          value = aws_service_discovery_service.ecs.name
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.ecs_service_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.ecs.arn
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution]

  tags = local.common_tags
}

############################
# SES
############################

resource "aws_ses_domain_identity" "this" {
  domain = var.ses_domain
}

resource "aws_ses_domain_dkim" "this" {
  domain = aws_ses_domain_identity.this.domain
}

resource "aws_ses_configuration_set" "this" {
  name = "${local.name_prefix}-ses-config-set"
}

############################
# Outputs
############################

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "cloud_map_namespace" {
  value = aws_service_discovery_private_dns_namespace.app.name
}

output "documentdb_endpoint" {
  value = aws_docdb_cluster.this.endpoint
}

output "rabbitmq_console_url" {
  value = aws_mq_broker.rabbitmq.instances[0].console_url
}

output "ses_verification_token" {
  value = aws_ses_domain_identity.this.verification_token
}