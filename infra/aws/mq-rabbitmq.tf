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
  description = "Prefix used for Amazon MQ for RabbitMQ resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the broker is deployed."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for broker deployment. Use at least two subnets for CLUSTER_MULTI_AZ."
  type        = list(string)
}

variable "spring_amqp_client_security_group_id" {
  description = "Security group ID used by Spring AMQP clients (for example ECS tasks)."
  type        = string
}

variable "management_cidr_blocks" {
  description = "CIDR blocks allowed to access RabbitMQ management endpoint over TLS (port 443)."
  type        = list(string)
  default     = []
}

variable "broker_engine_version" {
  description = "RabbitMQ engine version for Amazon MQ broker."
  type        = string
  default     = "3.11.28"
}

variable "host_instance_type" {
  description = "Broker instance type."
  type        = string
  default     = "mq.t3.micro"
}

variable "deployment_mode" {
  description = "Deployment mode for broker. Valid values: SINGLE_INSTANCE, CLUSTER_MULTI_AZ."
  type        = string
  default     = "SINGLE_INSTANCE"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.deployment_mode)
    error_message = "deployment_mode must be SINGLE_INSTANCE or CLUSTER_MULTI_AZ."
  }
}

variable "publicly_accessible" {
  description = "Whether broker is publicly accessible. Keep false for private VPC access from Spring clients."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Enable automatic minor version upgrades."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply broker modifications immediately."
  type        = bool
  default     = true
}

variable "rabbitmq_users" {
  description = "Broker users for application and operations access."
  type = list(object({
    username       = string
    password       = string
    console_access = optional(bool, false)
  }))

  validation {
    condition     = length(var.rabbitmq_users) > 0
    error_message = "At least one rabbitmq_users entry is required."
  }
}

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default     = {}
}

locals {
  broker_name = "${var.name_prefix}-rabbitmq"

  common_tags = merge(
    {
      Name      = local.broker_name
      ManagedBy = "terraform"
      Service   = "amazon_mq_rabbitmq"
    },
    var.tags
  )
}

resource "aws_security_group" "rabbitmq_broker" {
  name        = "${var.name_prefix}-rabbitmq-broker-sg"
  description = "Controls TLS connectivity to Amazon MQ RabbitMQ broker"
  vpc_id      = var.vpc_id

  tags = local.common_tags
}

resource "aws_security_group_rule" "amqps_from_spring_clients" {
  type                     = "ingress"
  description              = "Allow Spring AMQP clients to connect over AMQPS (TLS)"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rabbitmq_broker.id
  source_security_group_id = var.spring_amqp_client_security_group_id
}

resource "aws_security_group_rule" "management_tls_from_admin_networks" {
  count                    = length(var.management_cidr_blocks) > 0 ? 1 : 0
  type                     = "ingress"
  description              = "Allow management API/UI over TLS"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rabbitmq_broker.id
  cidr_blocks              = var.management_cidr_blocks
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  description       = "Allow broker egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.rabbitmq_broker.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_mq_broker" "rabbitmq" {
  broker_name                = local.broker_name
  engine_type                = "RabbitMQ"
  engine_version             = var.broker_engine_version
  host_instance_type         = var.host_instance_type
  deployment_mode            = var.deployment_mode
  subnet_ids                 = var.subnet_ids
  security_groups            = [aws_security_group.rabbitmq_broker.id]
  publicly_accessible        = var.publicly_accessible
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately
  authentication_strategy    = "simple"

  dynamic "user" {
    for_each = var.rabbitmq_users
    content {
      username       = user.value.username
      password       = user.value.password
      console_access = try(user.value.console_access, false)
    }
  }

  encryption_options {
    use_aws_owned_key = true
  }

  logs {
    general = true
  }

  maintenance_window_start_time {
    day_of_week = "SUNDAY"
    time_of_day = "03:00"
    time_zone   = "UTC"
  }

  tags = local.common_tags
}

output "rabbitmq_broker_id" {
  description = "Amazon MQ broker ID."
  value       = aws_mq_broker.rabbitmq.id
}

output "rabbitmq_broker_arn" {
  description = "Amazon MQ broker ARN."
  value       = aws_mq_broker.rabbitmq.arn
}

output "rabbitmq_endpoints" {
  description = "Broker endpoints for Spring AMQP clients (use AMQPS endpoint/port 5671)."
  value       = flatten([for i in aws_mq_broker.rabbitmq.instances : i.endpoints])
}

output "rabbitmq_security_group_id" {
  description = "Security group attached to the RabbitMQ broker."
  value       = aws_security_group.rabbitmq_broker.id
}