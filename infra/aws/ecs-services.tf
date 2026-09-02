terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

############################
# Inputs
############################

variable "project_name" {
  description = "Project or application name used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the existing ECS cluster (Fargate compatible)."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for ECS tasks."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to ECS services."
  type        = list(string)
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace ID for service discovery."
  type        = string
}

variable "service_connect_log_group_name" {
  description = "Optional CloudWatch log group for Service Connect proxy logs."
  type        = string
  default     = null
}

variable "services" {
  description = "Microservice configuration map keyed by logical service name."
  type = map(object({
    task_definition_arn                    = string
    container_name                         = string
    container_port                         = number
    desired_count                          = number
    deployment_minimum_healthy_percent     = number
    deployment_maximum_percent             = number
    health_check_grace_period_seconds      = optional(number, 30)
    enable_execute_command                 = optional(bool, true)
    assign_public_ip                       = optional(bool, false)
    platform_version                       = optional(string, "1.4.0")
    propagate_tags                         = optional(string, "SERVICE")
    scheduling_strategy                    = optional(string, "REPLICA")
    target_group_arn                       = optional(string)
    cloud_map_dns_ttl                      = optional(number, 10)
    cloud_map_routing_policy               = optional(string, "MULTIVALUE")
    service_connect_enabled                = optional(bool, true)
    deployment_circuit_breaker_enabled     = optional(bool, true)
    deployment_circuit_breaker_rollback    = optional(bool, true)
    force_new_deployment                   = optional(bool, true)
    enable_managed_tags                    = optional(bool, true)
    wait_for_steady_state                  = optional(bool, true)
    deployment_controller_type             = optional(string, "ECS")
    tags                                   = optional(map(string), {})
  }))
}

############################
# Locals
############################

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Workload    = "ecs-fargate"
    Messaging   = "amazon-mq-rabbitmq"
    Database    = "amazon-documentdb"
    Email       = "amazon-ses"
    Discovery   = "aws-cloud-map"
  }
}

############################
# Cloud Map service discovery
############################

resource "aws_service_discovery_service" "this" {
  for_each = var.services

  name = "${var.project_name}-${var.environment}-${each.key}"

  dns_config {
    namespace_id = var.service_discovery_namespace_id
    routing_policy = try(each.value.cloud_map_routing_policy, "MULTIVALUE")

    dns_records {
      type = "A"
      ttl  = try(each.value.cloud_map_dns_ttl, 10)
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = merge(local.common_tags, try(each.value.tags, {}), {
    Service = each.key
  })
}

############################
# ECS services (Fargate)
############################

resource "aws_ecs_service" "this" {
  for_each = var.services

  name            = "${var.project_name}-${var.environment}-${each.key}"
  cluster         = var.cluster_arn
  task_definition = each.value.task_definition_arn
  launch_type     = "FARGATE"
  desired_count   = each.value.desired_count

  platform_version = try(each.value.platform_version, "1.4.0")

  deployment_minimum_healthy_percent = each.value.deployment_minimum_healthy_percent
  deployment_maximum_percent         = each.value.deployment_maximum_percent
  health_check_grace_period_seconds  = try(each.value.health_check_grace_period_seconds, 30)

  scheduling_strategy    = try(each.value.scheduling_strategy, "REPLICA")
  enable_execute_command = try(each.value.enable_execute_command, true)
  enable_ecs_managed_tags = try(each.value.enable_managed_tags, true)
  propagate_tags          = try(each.value.propagate_tags, "SERVICE")
  force_new_deployment    = try(each.value.force_new_deployment, true)
  wait_for_steady_state   = try(each.value.wait_for_steady_state, true)

  deployment_controller {
    type = try(each.value.deployment_controller_type, "ECS")
  }

  deployment_circuit_breaker {
    enable   = try(each.value.deployment_circuit_breaker_enabled, true)
    rollback = try(each.value.deployment_circuit_breaker_rollback, true)
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = try(each.value.assign_public_ip, false)
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.this[each.key].arn
    container_name = each.value.container_name
    container_port = each.value.container_port
  }

  dynamic "service_connect_configuration" {
    for_each = try(each.value.service_connect_enabled, true) ? [1] : []

    content {
      enabled   = true
      namespace = var.service_discovery_namespace_id

      service {
        port_name      = each.value.container_name
        discovery_name = each.key

        client_alias {
          dns_name = each.key
          port     = each.value.container_port
        }
      }

      dynamic "log_configuration" {
        for_each = var.service_connect_log_group_name != null ? [1] : []
        content {
          log_driver = "awslogs"
          options = {
            awslogs-group         = var.service_connect_log_group_name
            awslogs-region        = regex("arn:aws:[^:]+:[^:]*:([0-9]{12}):.*", var.cluster_arn)[0]
            awslogs-stream-prefix = each.key
          }
        }
      }
    }
  }

  dynamic "load_balancer" {
    for_each = try(each.value.target_group_arn, null) != null && try(each.value.target_group_arn, "") != "" ? [1] : []

    content {
      target_group_arn = each.value.target_group_arn
      container_name   = each.value.container_name
      container_port   = each.value.container_port
    }
  }

  tags = merge(local.common_tags, try(each.value.tags, {}), {
    Service = each.key
  })

  depends_on = [
    aws_service_discovery_service.this
  ]
}

############################
# Outputs
############################

output "ecs_service_arns" {
  description = "ARNs of ECS services by microservice key."
  value = {
    for k, svc in aws_ecs_service.this : k => svc.arn
  }
}

output "ecs_service_names" {
  description = "Names of ECS services by microservice key."
  value = {
    for k, svc in aws_ecs_service.this : k => svc.name
  }
}

output "cloud_map_service_arns" {
  description = "Cloud Map service ARNs by microservice key."
  value = {
    for k, s in aws_service_discovery_service.this : k => s.arn
  }
}