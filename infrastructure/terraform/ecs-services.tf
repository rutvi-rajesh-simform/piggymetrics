terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  components = {
    gateway = {
      port   = 8080
      cpu    = 512
      memory = 1024
    }
    auth = {
      port   = 8081
      cpu    = 256
      memory = 512
    }
    account = {
      port   = 8082
      cpu    = 256
      memory = 512
    }
    statistics = {
      port   = 8083
      cpu    = 256
      memory = 512
    }
    notification = {
      port   = 8084
      cpu    = 256
      memory = 512
    }
    monitoring = {
      port   = 8085
      cpu    = 256
      memory = 512
    }
    turbine = {
      port   = 8086
      cpu    = 256
      memory = 512
    }
  }

  common_environment = [
    {
      name  = "AWS_REGION"
      value = var.aws_region
    },
    {
      name  = "ENVIRONMENT"
      value = var.environment
    },
    {
      name  = "CLOUD_MAP_NAMESPACE"
      value = var.cloud_map_namespace_name
    },
    {
      name  = "APPCONFIG_APPLICATION"
      value = var.appconfig_application_name
    },
    {
      name  = "APPCONFIG_ENVIRONMENT"
      value = var.appconfig_environment_name
    },
    {
      name  = "DOCUMENTDB_ENDPOINT"
      value = var.documentdb_endpoint
    },
    {
      name  = "SNS_TOPIC_ARN"
      value = var.sns_topic_arn
    },
    {
      name  = "SQS_QUEUE_URL"
      value = var.sqs_queue_url
    }
  ]
}

resource "aws_service_discovery_service" "component" {
  for_each = local.components

  name = "${var.project_name}-${var.environment}-${each.key}"

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

  tags = merge(var.tags, {
    Name      = "${var.project_name}-${var.environment}-${each.key}-discovery"
    Component = each.key
  })
}

resource "aws_ecs_task_definition" "component" {
  for_each = local.components

  family                   = "${var.project_name}-${var.environment}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = var.service_image_uris[each.key]
      essential = true

      portMappings = [
        {
          containerPort = each.value.port
          hostPort      = each.value.port
          protocol      = "tcp"
        }
      ]

      environment = concat(
        local.common_environment,
        [
          {
            name  = "SERVICE_NAME"
            value = each.key
          },
          {
            name  = "SERVICE_PORT"
            value = tostring(each.value.port)
          }
        ]
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.cloudwatch_log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = each.key
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${each.value.port}/actuator/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(var.tags, {
    Name      = "${var.project_name}-${var.environment}-${each.key}-task"
    Component = each.key
  })
}

resource "aws_ecs_service" "component" {
  for_each = local.components

  name                               = "${var.project_name}-${var.environment}-${each.key}"
  cluster                            = var.ecs_cluster_arn
  task_definition                    = aws_ecs_task_definition.component[each.key].arn
  desired_count                      = lookup(var.desired_count_by_service, each.key, 1)
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_service_security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.component[each.key].arn
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name      = "${var.project_name}-${var.environment}-${each.key}-service"
    Component = each.key
  })

  depends_on = [
    aws_service_discovery_service.component,
    aws_ecs_task_definition.component
  ]
}

variable "aws_region" {
  description = "AWS region for ECS services and supporting integrations."
  type        = string
}

variable "project_name" {
  description = "Project/application name used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster where services will run."
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "IAM role ARN used by ECS agent for pulling images and writing logs."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "IAM role ARN assumed by application containers."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks."
  type        = list(string)
}

variable "ecs_service_security_group_id" {
  description = "Security group ID attached to ECS services."
  type        = string
}

variable "cloud_map_namespace_id" {
  description = "Cloud Map private DNS namespace ID used for service discovery."
  type        = string
}

variable "cloud_map_namespace_name" {
  description = "Cloud Map namespace name used by application configuration."
  type        = string
}

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS containers."
  type        = string
}

variable "service_image_uris" {
  description = "Map of service component name to container image URI."
  type        = map(string)

  validation {
    condition = alltrue([
      for service_name in keys(local.components) : contains(keys(var.service_image_uris), service_name)
    ])
    error_message = "service_image_uris must include gateway, auth, account, statistics, notification, monitoring, and turbine keys."
  }
}

variable "desired_count_by_service" {
  description = "Optional desired count override per component service."
  type        = map(number)
  default     = {}
}

variable "appconfig_application_name" {
  description = "AWS AppConfig application name provided to containers."
  type        = string
}

variable "appconfig_environment_name" {
  description = "AWS AppConfig environment name provided to containers."
  type        = string
}

variable "documentdb_endpoint" {
  description = "Amazon DocumentDB endpoint used by services."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN used by services for pub/sub communication."
  type        = string
}

variable "sqs_queue_url" {
  description = "SQS queue URL used by services for asynchronous messaging."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default     = {}
}