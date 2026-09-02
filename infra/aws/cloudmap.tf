terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "name_prefix" {
  description = "Prefix used for Cloud Map resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the private DNS namespace will be created."
  type        = string
}

variable "cloudmap_namespace_name" {
  description = "Private DNS namespace name (e.g. internal.example.local)."
  type        = string
}

variable "cloudmap_services" {
  description = "Cloud Map services to create for service discovery."
  type = map(object({
    dns_record_type                       = optional(string, "A")
    dns_ttl                               = optional(number, 10)
    routing_policy                        = optional(string, "MULTIVALUE")
    failure_threshold                     = optional(number, 1)
    custom_health_check_failure_threshold = optional(number, 1)
  }))

  default = {
    ecs-fargate = {
      dns_record_type                       = "A"
      dns_ttl                               = 10
      routing_policy                        = "MULTIVALUE"
      custom_health_check_failure_threshold = 1
    }
    documentdb = {
      dns_record_type                       = "CNAME"
      dns_ttl                               = 30
      routing_policy                        = "WEIGHTED"
      custom_health_check_failure_threshold = 1
    }
    rabbitmq = {
      dns_record_type                       = "A"
      dns_ttl                               = 10
      routing_policy                        = "MULTIVALUE"
      custom_health_check_failure_threshold = 1
    }
  }
}

variable "static_instances" {
  description = "Optional static Cloud Map instance registrations (non-ECS endpoints). Key format: <service_name>/<instance_id>."
  type = map(object({
    service_name = string
    instance_id  = string
    ipv4         = optional(string)
    cname        = optional(string)
    port         = optional(number)
    attributes   = optional(map(string), {})
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to Cloud Map resources."
  type        = map(string)
  default     = {}
}

locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Component = "cloud-map"
  })
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.cloudmap_namespace_name
  description = "Private namespace for inter-service discovery"
  vpc         = var.vpc_id
  tags        = local.common_tags
}

resource "aws_service_discovery_service" "this" {
  for_each = var.cloudmap_services

  name = "${var.name_prefix}-${each.key}"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = each.value.routing_policy

    dns_records {
      type = each.value.dns_record_type
      ttl  = each.value.dns_ttl
    }
  }

  health_check_custom_config {
    failure_threshold = each.value.custom_health_check_failure_threshold
  }

  tags = merge(local.common_tags, {
    Service = each.key
  })
}

resource "aws_service_discovery_instance" "static" {
  for_each = {
    for k, v in var.static_instances : k => v
    if contains(keys(aws_service_discovery_service.this), v.service_name)
  }

  service_id  = aws_service_discovery_service.this[each.value.service_name].id
  instance_id = each.value.instance_id

  attributes = merge(
    each.value.attributes,
    each.value.ipv4 != null ? { AWS_INSTANCE_IPV4 = each.value.ipv4 } : {},
    each.value.cname != null ? { AWS_INSTANCE_CNAME = each.value.cname } : {},
    each.value.port != null ? { AWS_INSTANCE_PORT = tostring(each.value.port) } : {}
  )
}

output "cloudmap_namespace_id" {
  description = "Cloud Map private DNS namespace ID."
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "cloudmap_namespace_arn" {
  description = "Cloud Map private DNS namespace ARN."
  value       = aws_service_discovery_private_dns_namespace.this.arn
}

output "cloudmap_service_ids" {
  description = "Map of Cloud Map service IDs by logical service key."
  value       = { for k, svc in aws_service_discovery_service.this : k => svc.id }
}

output "cloudmap_service_arns" {
  description = "Map of Cloud Map service ARNs by logical service key."
  value       = { for k, svc in aws_service_discovery_service.this : k => svc.arn }
}