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

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.service_name}-ecs-task-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.service_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ecs_task_permissions" {
  statement {
    sid = "AllowSqsOperations"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl"
    ]
    resources = var.sqs_queue_arns
  }

  statement {
    sid = "AllowSnsPublish"
    actions = [
      "sns:Publish"
    ]
    resources = var.sns_topic_arns
  }

  statement {
    sid = "AllowAppConfigRead"
    actions = [
      "appconfig:StartConfigurationSession",
      "appconfig:GetLatestConfiguration"
    ]
    resources = var.appconfig_configuration_profile_arns
  }

  statement {
    sid = "AllowCloudMapDiscovery"
    actions = [
      "servicediscovery:DiscoverInstances",
      "servicediscovery:DiscoverInstancesRevision"
    ]
    resources = var.cloud_map_discovery_arns
  }

  statement {
    sid = "AllowDocumentDbIamAuth"
    actions = [
      "rds-db:connect"
    ]
    resources = var.documentdb_dbuser_arns
  }

  statement {
    sid = "AllowSecretsRetrieval"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = var.secret_arns
  }
}

resource "aws_iam_policy" "ecs_task" {
  name   = "${var.service_name}-ecs-task-policy"
  policy = data.aws_iam_policy_document.ecs_task_permissions.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_custom" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task.arn
}

resource "aws_security_group" "ecs_service" {
  name        = "${var.service_name}-ecs-sg"
  description = "Security group for ECS Fargate service ${var.service_name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "Application ingress"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = var.service_ingress_cidr_blocks
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_service_discovery_service" "this" {
  count = var.enable_cloud_map ? 1 : 0

  name = var.service_name

  dns_config {
    namespace_id = var.cloud_map_namespace_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }

      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "APP_NAME"
          value = var.service_name
        },
        {
          name  = "APPCONFIG_APPLICATION"
          value = var.appconfig_application_name
        },
        {
          name  = "APPCONFIG_ENVIRONMENT"
          value = var.appconfig_environment_name
        }
      ]
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name                   = var.service_name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = concat([aws_security_group.ecs_service.id], var.additional_security_group_ids)
    assign_public_ip = var.assign_public_ip
  }

  dynamic "service_registries" {
    for_each = var.enable_cloud_map ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.this[0].arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_managed,
    aws_iam_role_policy_attachment.ecs_task_custom
  ]

  tags = var.tags
}

variable "aws_region" {
  type        = string
  description = "AWS region for ECS resources."
}

variable "ecs_cluster_name" {
  type        = string
  description = "Name of the ECS cluster."
}

variable "service_name" {
  type        = string
  description = "Microservice name used for ECS service and task definition family."
}

variable "container_image" {
  type        = string
  description = "Container image URI (typically ECR URI:tag)."
}

variable "container_port" {
  type        = number
  description = "Container port exposed by the application."
  default     = 8080
}

variable "task_cpu" {
  type        = number
  description = "Fargate task CPU units."
  default     = 256
}

variable "task_memory" {
  type        = number
  description = "Fargate task memory (MiB)."
  default     = 512
}

variable "desired_count" {
  type        = number
  description = "Desired number of running tasks."
  default     = 1
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where ECS service will run."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnets for ECS tasks."
}

variable "service_ingress_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the service port."
  default     = ["10.0.0.0/8"]
}

variable "additional_security_group_ids" {
  type        = list(string)
  description = "Additional security groups to attach to ECS tasks."
  default     = []
}

variable "assign_public_ip" {
  type        = bool
  description = "Assign a public IP to task ENIs."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention for ECS logs."
  default     = 14
}

variable "enable_cloud_map" {
  type        = bool
  description = "Whether to create Cloud Map service discovery registration."
  default     = true
}

variable "cloud_map_namespace_id" {
  type        = string
  description = "Cloud Map private DNS namespace ID. Required when enable_cloud_map=true."
  default     = null
}

variable "sqs_queue_arns" {
  type        = list(string)
  description = "SQS queue ARNs the task can access."
  default     = []
}

variable "sns_topic_arns" {
  type        = list(string)
  description = "SNS topic ARNs the task can publish to."
  default     = []
}

variable "appconfig_configuration_profile_arns" {
  type        = list(string)
  description = "AppConfig configuration profile ARNs available to tasks."
  default     = []
}

variable "cloud_map_discovery_arns" {
  type        = list(string)
  description = "Cloud Map ARNs allowed for service discovery API calls."
  default     = []
}

variable "documentdb_dbuser_arns" {
  type        = list(string)
  description = "DocumentDB IAM DB user ARNs for rds-db:connect permissions."
  default     = []
}

variable "secret_arns" {
  type        = list(string)
  description = "Secrets Manager secret ARNs readable by the task."
  default     = []
}

variable "appconfig_application_name" {
  type        = string
  description = "AppConfig application name exposed to the container."
  default     = ""
}

variable "appconfig_environment_name" {
  type        = string
  description = "AppConfig environment name exposed to the container."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
  default     = {}
}

output "ecs_cluster_arn" {
  value       = aws_ecs_cluster.this.arn
  description = "ARN of the ECS cluster."
}

output "ecs_service_name" {
  value       = aws_ecs_service.this.name
  description = "Name of the ECS service."
}

output "ecs_task_execution_role_arn" {
  value       = aws_iam_role.ecs_task_execution.arn
  description = "ARN of ECS task execution role."
}

output "ecs_task_role_arn" {
  value       = aws_iam_role.ecs_task.arn
  description = "ARN of ECS task role for application permissions."
}

output "ecs_service_security_group_id" {
  value       = aws_security_group.ecs_service.id
  description = "Security group ID attached to ECS tasks."
}