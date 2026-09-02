terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  cidr_ingress_rules = {
    for rule in flatten([
      for service_name, service_cfg in var.documentdb_services : [
        for cidr in try(service_cfg.allowed_cidr_blocks, []) : {
          key          = "${service_name}-${replace(cidr, "/", "-")}"
          service_name = service_name
          cidr         = cidr
        }
      ]
    ]) : rule.key => rule
  }

  sg_ingress_rules = {
    for rule in flatten([
      for service_name, service_cfg in var.documentdb_services : [
        for source_sg_id in try(service_cfg.allowed_security_group_ids, []) : {
          key          = "${service_name}-${source_sg_id}"
          service_name = service_name
          source_sg_id = source_sg_id
        }
      ]
    ]) : rule.key => rule
  }

  cluster_instances = {
    for instance in flatten([
      for service_name, service_cfg in var.documentdb_services : [
        for idx in range(try(service_cfg.cluster_size, 1)) : {
          key            = "${service_name}-${idx + 1}"
          service_name   = service_name
          instance_index = idx + 1
          instance_class = try(service_cfg.instance_class, "db.t3.medium")
        }
      ]
    ]) : instance.key => instance
  }
}

resource "aws_docdb_subnet_group" "service" {
  for_each = var.documentdb_services

  name       = "${local.name_prefix}-${each.key}-docdb-subnet"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name        = "${local.name_prefix}-${each.key}-docdb-subnet"
    Service     = each.key
    Environment = var.environment
  })
}

resource "aws_docdb_cluster_parameter_group" "service" {
  for_each = var.documentdb_services

  name   = "${local.name_prefix}-${each.key}-docdb-params"
  family = var.documentdb_parameter_family

  parameter {
    name  = "tls"
    value = "enabled"
  }

  parameter {
    name         = "audit_logs"
    value        = "enabled"
    apply_method = "pending-reboot"
  }

  tags = merge(var.tags, {
    Name        = "${local.name_prefix}-${each.key}-docdb-params"
    Service     = each.key
    Environment = var.environment
  })
}

resource "aws_security_group" "documentdb" {
  for_each = var.documentdb_services

  name        = "${local.name_prefix}-${each.key}-docdb-sg"
  description = "DocumentDB security group for service ${each.key}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name        = "${local.name_prefix}-${each.key}-docdb-sg"
    Service     = each.key
    Environment = var.environment
  })
}

resource "aws_security_group_rule" "documentdb_ingress_cidr" {
  for_each = local.cidr_ingress_rules

  type              = "ingress"
  from_port         = 27017
  to_port           = 27017
  protocol          = "tcp"
  security_group_id = aws_security_group.documentdb[each.value.service_name].id
  cidr_blocks       = [each.value.cidr]
  description       = "Allow Mongo-compatible DocumentDB traffic from CIDR ${each.value.cidr}"
}

resource "aws_security_group_rule" "documentdb_ingress_sg" {
  for_each = local.sg_ingress_rules

  type                     = "ingress"
  from_port                = 27017
  to_port                  = 27017
  protocol                 = "tcp"
  security_group_id        = aws_security_group.documentdb[each.value.service_name].id
  source_security_group_id = each.value.source_sg_id
  description              = "Allow Mongo-compatible DocumentDB traffic from source SG ${each.value.source_sg_id}"
}

resource "aws_docdb_cluster" "service" {
  for_each = var.documentdb_services

  cluster_identifier              = "${local.name_prefix}-${each.key}-docdb"
  engine                          = "docdb"
  master_username                 = each.value.master_username
  master_password                 = each.value.master_password
  db_subnet_group_name            = aws_docdb_subnet_group.service[each.key].name
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.service[each.key].name
  vpc_security_group_ids          = [aws_security_group.documentdb[each.key].id]

  storage_encrypted               = true
  kms_key_id                      = var.kms_key_arn
  backup_retention_period         = try(each.value.backup_retention_period, 7)
  preferred_backup_window         = try(each.value.preferred_backup_window, "03:00-04:00")
  preferred_maintenance_window    = try(each.value.preferred_maintenance_window, "sun:05:00-sun:06:00")
  enabled_cloudwatch_logs_exports = ["audit", "profiler"]

  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name_prefix}-${each.key}-docdb-final"
  apply_immediately       = var.apply_immediately

  tags = merge(var.tags, {
    Name        = "${local.name_prefix}-${each.key}-docdb"
    Service     = each.key
    Environment = var.environment
  })
}

resource "aws_docdb_cluster_instance" "service" {
  for_each = local.cluster_instances

  identifier         = "${local.name_prefix}-${each.value.service_name}-docdb-${each.value.instance_index}"
  cluster_identifier = aws_docdb_cluster.service[each.value.service_name].id
  instance_class     = each.value.instance_class
  apply_immediately  = var.apply_immediately

  tags = merge(var.tags, {
    Name        = "${local.name_prefix}-${each.value.service_name}-docdb-${each.value.instance_index}"
    Service     = each.value.service_name
    Environment = var.environment
  })
}

variable "project_name" {
  description = "Project or application name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where DocumentDB resources will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for DocumentDB subnet groups"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for storage encryption. If null, AWS managed key is used"
  type        = string
  default     = null
}

variable "documentdb_parameter_family" {
  description = "DocumentDB parameter group family"
  type        = string
  default     = "docdb5.0"
}

variable "deletion_protection" {
  description = "Enable deletion protection on DocumentDB clusters"
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on cluster deletion"
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications immediately or during maintenance window"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "documentdb_services" {
  description = "Per-service DocumentDB cluster configuration"
  type = map(object({
    master_username            = string
    master_password            = string
    database_name              = optional(string, "app")
    instance_class             = optional(string, "db.t3.medium")
    cluster_size               = optional(number, 1)
    backup_retention_period    = optional(number, 7)
    preferred_backup_window    = optional(string, "03:00-04:00")
    preferred_maintenance_window = optional(string, "sun:05:00-sun:06:00")
    allowed_cidr_blocks        = optional(list(string), [])
    allowed_security_group_ids = optional(list(string), [])
  }))
}

output "documentdb_cluster_endpoints" {
  description = "DocumentDB cluster endpoints by service"
  value = {
    for service_name, cluster in aws_docdb_cluster.service :
    service_name => cluster.endpoint
  }
}

output "documentdb_reader_endpoints" {
  description = "DocumentDB cluster reader endpoints by service"
  value = {
    for service_name, cluster in aws_docdb_cluster.service :
    service_name => cluster.reader_endpoint
  }
}

output "documentdb_security_group_ids" {
  description = "Security group IDs assigned to each service DocumentDB cluster"
  value = {
    for service_name, sg in aws_security_group.documentdb :
    service_name => sg.id
  }
}