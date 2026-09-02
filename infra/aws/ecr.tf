terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "name_prefix" {
  description = "Prefix used for ECR repository names (for example: app-dev or piggymetrics-prod)."
  type        = string
  default     = "piggymetrics"
}

variable "force_delete" {
  description = "Delete ECR repositories even if they contain images."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to all ECR repositories."
  type        = map(string)
  default     = {}
}

locals {
  microservice_images = toset([
    "config",
    "registry",
    "gateway",
    "auth-service",
    "account-service",
    "statistics-service",
    "notification-service",
    "monitoring",
    "turbine-stream-service"
  ])
}

resource "aws_ecr_repository" "microservice" {
  for_each = local.microservice_images

  name                 = "${var.name_prefix}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-${each.value}"
    Service     = each.value
    ManagedBy   = "terraform"
    Workload    = "ecs"
    Cloud       = "aws"
  })
}

resource "aws_ecr_lifecycle_policy" "microservice" {
  for_each = aws_ecr_repository.microservice

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by microservice name."
  value       = { for service, repo in aws_ecr_repository.microservice : service => repo.repository_url }
}

output "ecr_repository_arns" {
  description = "ECR repository ARNs keyed by microservice name."
  value       = { for service, repo in aws_ecr_repository.microservice : service => repo.arn }
}