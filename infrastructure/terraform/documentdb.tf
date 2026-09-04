terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

resource "aws_docdb_subnet_group" "this" {
  name       = var.docdb_subnet_group_name
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = var.docdb_subnet_group_name
    }
  )
}

resource "aws_docdb_cluster_parameter_group" "this" {
  name        = var.docdb_parameter_group_name
  family      = var.parameter_group_family
  description = "DocumentDB cluster parameter group for ${var.docdb_cluster_identifier}"

  parameter {
    name         = "tls"
    value        = var.enable_tls ? "enabled" : "disabled"
    apply_method = "pending-reboot"
  }

  tags = merge(
    var.tags,
    {
      Name = var.docdb_parameter_group_name
    }
  )
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier              = var.docdb_cluster_identifier
  engine                          = "docdb"
  engine_version                  = var.engine_version
  master_username                 = var.master_username
  master_password                 = var.master_password
  db_subnet_group_name            = aws_docdb_subnet_group.this.name
  vpc_security_group_ids          = var.vpc_security_group_ids
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name
  port                            = var.db_port

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window

  storage_encrypted            = var.storage_encrypted
  kms_key_id                   = var.kms_key_id
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  apply_immediately    = var.apply_immediately
  deletion_protection  = var.deletion_protection
  skip_final_snapshot  = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.docdb_cluster_identifier}-final"

  tags = merge(
    var.tags,
    {
      Name = var.docdb_cluster_identifier
    }
  )
}

resource "aws_docdb_cluster_instance" "this" {
  count = var.instance_count

  identifier         = format("%s-%02d", var.docdb_cluster_identifier, count.index + 1)
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.instance_class

  apply_immediately = var.apply_immediately

  tags = merge(
    var.tags,
    {
      Name = format("%s-%02d", var.docdb_cluster_identifier, count.index + 1)
    }
  )
}

variable "docdb_cluster_identifier" {
  description = "Unique identifier for the Amazon DocumentDB cluster."
  type        = string
  default     = "app-docdb-cluster"
}

variable "docdb_subnet_group_name" {
  description = "Name of the DocumentDB subnet group."
  type        = string
  default     = "app-docdb-subnet-group"
}

variable "docdb_parameter_group_name" {
  description = "Name of the DocumentDB cluster parameter group."
  type        = string
  default     = "app-docdb-parameter-group"
}

variable "parameter_group_family" {
  description = "DocumentDB parameter group family (for example, docdb5.0)."
  type        = string
  default     = "docdb5.0"
}

variable "engine_version" {
  description = "DocumentDB engine version."
  type        = string
  default     = "5.0.0"
}

variable "master_username" {
  description = "Master username for the DocumentDB cluster."
  type        = string
}

variable "master_password" {
  description = "Master password for the DocumentDB cluster."
  type        = string
  sensitive   = true
}

variable "subnet_ids" {
  description = "List of private subnet IDs for the DocumentDB subnet group."
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "List of VPC security group IDs attached to the DocumentDB cluster."
  type        = list(string)
}

variable "db_port" {
  description = "Port on which the DocumentDB cluster accepts connections."
  type        = number
  default     = 27017
}

variable "instance_count" {
  description = "Number of DocumentDB instances in the cluster."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "instance_class" {
  description = "Instance class for DocumentDB instances."
  type        = string
  default     = "db.r6g.large"
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups."
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily time range during which automated backups are created (UTC)."
  type        = string
  default     = "02:00-03:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly time range during which maintenance can occur (UTC)."
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "storage_encrypted" {
  description = "Whether to enable storage encryption."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key ARN for storage encryption. If null, AWS managed key is used."
  type        = string
  default     = null
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to CloudWatch Logs."
  type        = list(string)
  default     = ["audit", "profiler"]
}

variable "enable_tls" {
  description = "Whether TLS is enabled for DocumentDB connections."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Whether modifications are applied immediately or during the next maintenance window."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Whether to enable deletion protection for the cluster."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Whether to skip creating a final snapshot when deleting the cluster."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all DocumentDB resources."
  type        = map(string)
  default     = {}
}

output "docdb_cluster_arn" {
  description = "ARN of the DocumentDB cluster."
  value       = aws_docdb_cluster.this.arn
}

output "docdb_cluster_endpoint" {
  description = "Writer endpoint of the DocumentDB cluster."
  value       = aws_docdb_cluster.this.endpoint
}

output "docdb_cluster_reader_endpoint" {
  description = "Reader endpoint of the DocumentDB cluster."
  value       = aws_docdb_cluster.this.reader_endpoint
}

output "docdb_subnet_group_name" {
  description = "Name of the DocumentDB subnet group."
  value       = aws_docdb_subnet_group.this.name
}

output "docdb_parameter_group_name" {
  description = "Name of the DocumentDB cluster parameter group."
  value       = aws_docdb_cluster_parameter_group.this.name
}