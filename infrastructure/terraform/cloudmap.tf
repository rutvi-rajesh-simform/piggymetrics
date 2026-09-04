terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "cloud_map_namespace_name" {
  description = "Private DNS namespace name for ECS service discovery (for example: internal.local)."
  type        = string
}

variable "cloud_map_namespace_description" {
  description = "Description for the Cloud Map private DNS namespace."
  type        = string
  default     = "Service discovery namespace for ECS-hosted microservices"
}

variable "vpc_id" {
  description = "VPC ID where the private DNS namespace will be created."
  type        = string
}

variable "ecs_microservices" {
  description = "Map of ECS-hosted microservices to register in Cloud Map. Key is service name."
  type = map(object({
    dns_ttl           = optional(number, 10)
    routing_policy    = optional(string, "MULTIVALUE")
    failure_threshold = optional(number, 1)
  }))
}

variable "tags" {
  description = "Tags applied to Cloud Map resources."
  type        = map(string)
  default     = {}
}

resource "aws_service_discovery_private_dns_namespace" "ecs" {
  name        = var.cloud_map_namespace_name
  description = var.cloud_map_namespace_description
  vpc         = var.vpc_id
  tags        = var.tags
}

resource "aws_service_discovery_service" "ecs" {
  for_each = var.ecs_microservices

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ecs.id

    dns_records {
      type = "A"
      ttl  = each.value.dns_ttl
    }

    routing_policy = each.value.routing_policy
  }

  health_check_custom_config {
    failure_threshold = each.value.failure_threshold
  }

  tags = var.tags
}

output "cloud_map_namespace_id" {
  description = "Cloud Map namespace ID."
  value       = aws_service_discovery_private_dns_namespace.ecs.id
}

output "cloud_map_namespace_arn" {
  description = "Cloud Map namespace ARN."
  value       = aws_service_discovery_private_dns_namespace.ecs.arn
}

output "cloud_map_service_ids" {
  description = "Map of microservice name to Cloud Map service ID."
  value       = { for name, svc in aws_service_discovery_service.ecs : name => svc.id }
}

output "cloud_map_service_arns" {
  description = "Map of microservice name to Cloud Map service ARN."
  value       = { for name, svc in aws_service_discovery_service.ecs : name => svc.arn }
}