variable "ecs_cluster_name" {
  description = "Name of the ECS cluster for Fargate workloads."
  type        = string
}

variable "ecs_container_insights" {
  description = "Enable CloudWatch Container Insights at cluster level."
  type        = bool
  default     = true
}

variable "enable_fargate_spot" {
  description = "Whether to include FARGATE_SPOT as a cluster capacity provider."
  type        = bool
  default     = true
}

variable "fargate_base" {
  description = "Base tasks to run on FARGATE before applying weights."
  type        = number
  default     = 1
}

variable "fargate_weight" {
  description = "Relative weight for FARGATE in default capacity provider strategy."
  type        = number
  default     = 1
}

variable "fargate_spot_base" {
  description = "Base tasks to run on FARGATE_SPOT before applying weights."
  type        = number
  default     = 0
}

variable "fargate_spot_weight" {
  description = "Relative weight for FARGATE_SPOT in default capacity provider strategy."
  type        = number
  default     = 1
}

variable "cloud_map_namespace_arn" {
  description = "Optional AWS Cloud Map namespace ARN for Service Connect defaults."
  type        = string
  default     = null
}

variable "ecs_exec_logging" {
  description = "ECS Exec logging mode: NONE, DEFAULT, or OVERRIDE."
  type        = string
  default     = "OVERRIDE"

  validation {
    condition     = contains(["NONE", "DEFAULT", "OVERRIDE"], var.ecs_exec_logging)
    error_message = "ecs_exec_logging must be one of: NONE, DEFAULT, OVERRIDE."
  }
}

variable "ecs_exec_kms_key_id" {
  description = "Optional KMS key ARN/ID for ECS Exec session encryption."
  type        = string
  default     = null
}

variable "create_ecs_exec_log_group" {
  description = "Create a dedicated CloudWatch log group for ECS Exec when using OVERRIDE logging."
  type        = bool
  default     = true
}

variable "ecs_exec_log_group_name" {
  description = "CloudWatch log group name for ECS Exec logs."
  type        = string
  default     = "/aws/ecs/exec"
}

variable "ecs_exec_log_retention_days" {
  description = "Retention period for ECS Exec CloudWatch logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags to apply to all supported resources."
  type        = map(string)
  default     = {}
}

locals {
  ecs_exec_log_group_name_effective = var.create_ecs_exec_log_group ? aws_cloudwatch_log_group.ecs_exec[0].name : var.ecs_exec_log_group_name

  capacity_provider_strategy = var.enable_fargate_spot ? [
    {
      capacity_provider = "FARGATE"
      base              = var.fargate_base
      weight            = var.fargate_weight
    },
    {
      capacity_provider = "FARGATE_SPOT"
      base              = var.fargate_spot_base
      weight            = var.fargate_spot_weight
    }
    ] : [
    {
      capacity_provider = "FARGATE"
      base              = var.fargate_base
      weight            = var.fargate_weight
    }
  ]
}

resource "aws_cloudwatch_log_group" "ecs_exec" {
  count             = var.create_ecs_exec_log_group ? 1 : 0
  name              = var.ecs_exec_log_group_name
  retention_in_days = var.ecs_exec_log_retention_days
  tags              = merge(var.tags, { Name = var.ecs_exec_log_group_name })
}

resource "aws_ecs_cluster" "this" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = var.ecs_container_insights ? "enabled" : "disabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = var.ecs_exec_kms_key_id
      logging    = var.ecs_exec_logging

      dynamic "log_configuration" {
        for_each = var.ecs_exec_logging == "OVERRIDE" ? [1] : []
        content {
          cloud_watch_log_group_name = local.ecs_exec_log_group_name_effective
        }
      }
    }
  }

  dynamic "service_connect_defaults" {
    for_each = var.cloud_map_namespace_arn != null && trim(var.cloud_map_namespace_arn) != "" ? [1] : []
    content {
      namespace = var.cloud_map_namespace_arn
    }
  }

  tags = merge(var.tags, { Name = var.ecs_cluster_name })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = var.enable_fargate_spot ? ["FARGATE", "FARGATE_SPOT"] : ["FARGATE"]

  dynamic "default_capacity_provider_strategy" {
    for_each = local.capacity_provider_strategy
    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      base              = default_capacity_provider_strategy.value.base
      weight            = default_capacity_provider_strategy.value.weight
    }
  }
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}