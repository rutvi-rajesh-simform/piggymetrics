terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "project_name" {
  description = "Project identifier used in resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Redis will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ElastiCache subnet group."
  type        = list(string)
}

variable "ecs_service_security_group_ids" {
  description = "Security group IDs for ECS services that need Redis access."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "Optional CIDR blocks allowed to connect to Redis (for bastion/admin access)."
  type        = list(string)
  default     = []
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "redis_parameter_group_family" {
  description = "ElastiCache parameter group family matching the Redis engine major version."
  type        = string
  default     = "redis7"
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

variable "num_cache_clusters" {
  description = "Number of cache clusters in the replication group (>=2 enables failover)."
  type        = number
  default     = 2
}

variable "transit_encryption_enabled" {
  description = "Enable in-transit encryption (TLS)."
  type        = bool
  default     = true
}

variable "at_rest_encryption_enabled" {
  description = "Enable at-rest encryption."
  type        = bool
  default     = true
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots."
  type        = number
  default     = 1
}

variable "snapshot_window" {
  description = "Daily time range (UTC) during which snapshots are created."
  type        = string
  default     = "03:00-04:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly time range (UTC) for maintenance."
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "apply_immediately" {
  description = "Whether changes should be applied immediately or during maintenance window."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

locals {
  name_prefix          = "${var.project_name}-${var.environment}"
  replication_group_id = substr(regexreplace(lower("${var.project_name}-${var.environment}-redis"), "[^a-z0-9-]", "-"), 0, 40)

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "elasticache-redis"
  })
}

resource "aws_elasticache_subnet_group" "redis" {
  name        = "${local.name_prefix}-redis-subnet-group"
  description = "Subnet group for shared Redis cache"
  subnet_ids  = var.private_subnet_ids

  tags = local.common_tags
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Allow ECS services to access shared Redis cache"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-sg"
  })
}

resource "aws_security_group_rule" "redis_ingress_from_ecs" {
  for_each                 = toset(var.ecs_service_security_group_ids)
  type                     = "ingress"
  from_port                = var.redis_port
  to_port                  = var.redis_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = each.value
  description              = "Allow Redis access from ECS service SG ${each.value}"
}

resource "aws_security_group_rule" "redis_ingress_from_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  type              = "ingress"
  from_port         = var.redis_port
  to_port           = var.redis_port
  protocol          = "tcp"
  security_group_id = aws_security_group.redis.id
  cidr_blocks       = [each.value]
  description       = "Optional Redis access from ${each.value}"
}

resource "aws_security_group_rule" "redis_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.redis.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound traffic"
}

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${local.name_prefix}-redis-params"
  family      = var.redis_parameter_group_family
  description = "Parameter group for shared Redis cache"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = local.common_tags
}

resource "aws_elasticache_replication_group" "shared" {
  replication_group_id       = local.replication_group_id
  description                = "Shared Redis cache for low-latency read caching across ECS microservices"
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  node_type                  = var.redis_node_type
  num_cache_clusters         = var.num_cache_clusters
  port                       = var.redis_port
  parameter_group_name       = aws_elasticache_parameter_group.redis.name
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  transit_encryption_enabled = var.transit_encryption_enabled
  at_rest_encryption_enabled = var.at_rest_encryption_enabled

  snapshot_retention_limit    = var.snapshot_retention_limit
  snapshot_window             = var.snapshot_window
  preferred_maintenance_window = var.preferred_maintenance_window
  auto_minor_version_upgrade  = true
  apply_immediately           = var.apply_immediately

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis"
  })
}

output "redis_primary_endpoint" {
  description = "Primary endpoint for read/write Redis operations."
  value       = aws_elasticache_replication_group.shared.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Reader endpoint for read-only Redis traffic."
  value       = aws_elasticache_replication_group.shared.reader_endpoint_address
}

output "redis_port" {
  description = "Redis port exposed by the replication group."
  value       = aws_elasticache_replication_group.shared.port
}

output "redis_security_group_id" {
  description = "Security group ID attached to the Redis replication group."
  value       = aws_security_group.redis.id
}

output "redis_connection_uri" {
  description = "Redis URI for application configuration (rediss when TLS is enabled)."
  value       = format("%s://%s:%d", var.transit_encryption_enabled ? "rediss" : "redis", aws_elasticache_replication_group.shared.primary_endpoint_address, aws_elasticache_replication_group.shared.port)
}
