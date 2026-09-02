terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "project_name" {
  description = "Project/application name used in resource naming."
  type        = string
  default     = "piggymetrics"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "log_retention_days" {
  description = "CloudWatch log retention period for ECS service log groups."
  type        = number
  default     = 30
}

variable "ecs_cluster_name" {
  description = "ECS cluster name hosting core microservices."
  type        = string
  default     = "piggymetrics-cluster"
}

variable "ecs_service_names" {
  description = "Core ECS services to monitor and alert on."
  type        = list(string)
  default = [
    "config",
    "registry",
    "gateway",
    "auth-service",
    "account-service",
    "statistics-service",
    "notification-service",
    "monitoring",
    "turbine-stream-service"
  ]
}

variable "documentdb_cluster_identifier" {
  description = "DocumentDB cluster identifier for CloudWatch dimensions."
  type        = string
  default     = "piggymetrics-docdb"
}

variable "amazonmq_broker_name" {
  description = "Amazon MQ (RabbitMQ) broker name for CloudWatch dimensions."
  type        = string
  default     = "piggymetrics-rabbitmq"
}

variable "alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications. Leave empty to disable alarm actions."
  type        = string
  default     = ""
}

variable "ecs_cpu_high_threshold" {
  description = "High CPU threshold (%) for ECS services."
  type        = number
  default     = 80
}

variable "ecs_memory_high_threshold" {
  description = "High memory threshold (%) for ECS services."
  type        = number
  default     = 85
}

variable "ecs_running_task_minimum" {
  description = "Minimum healthy running task count per ECS service."
  type        = number
  default     = 1
}

variable "documentdb_cpu_high_threshold" {
  description = "High CPU threshold (%) for DocumentDB cluster."
  type        = number
  default     = 75
}

variable "documentdb_connections_high_threshold" {
  description = "High connection threshold for DocumentDB cluster."
  type        = number
  default     = 800
}

variable "documentdb_freeable_memory_low_bytes" {
  description = "Low freeable memory threshold (bytes) for DocumentDB cluster."
  type        = number
  default     = 536870912
}

variable "amazonmq_cpu_high_threshold" {
  description = "High CPU threshold (%) for Amazon MQ broker."
  type        = number
  default     = 75
}

variable "amazonmq_memory_used_high_threshold_bytes" {
  description = "High memory used threshold (bytes) for RabbitMQ broker."
  type        = number
  default     = 3221225472
}

variable "amazonmq_disk_free_low_threshold_bytes" {
  description = "Low free disk threshold (bytes) for RabbitMQ broker."
  type        = number
  default     = 2147483648
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  alarm_actions = var.alarm_topic_arn != "" ? [var.alarm_topic_arn] : []

  ecs_cpu_metrics = flatten([
    for svc in var.ecs_service_names : [
      ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", svc, { "stat" = "Average", "label" = "${svc} CPU %" }]
    ]
  ])

  ecs_memory_metrics = flatten([
    for svc in var.ecs_service_names : [
      ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", svc, { "stat" = "Average", "label" = "${svc} Memory %" }]
    ]
  ])

  ecs_running_metrics = flatten([
    for svc in var.ecs_service_names : [
      ["AWS/ECS", "RunningTaskCount", "ClusterName", var.ecs_cluster_name, "ServiceName", svc, { "stat" = "Minimum", "label" = "${svc} Running Tasks" }]
    ]
  ])
}

resource "aws_cloudwatch_log_group" "ecs_service_logs" {
  for_each = toset(var.ecs_service_names)

  name              = "/aws/ecs/${local.name_prefix}/${each.value}"
  retention_in_days = var.log_retention_days

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Service     = each.value
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-ecs-${each.value}-cpu-high"
  alarm_description   = "ECS service ${each.value} CPU utilization is above ${var.ecs_cpu_high_threshold}%"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.ecs_cpu_high_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "ecs-service-health"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-ecs-${each.value}-memory-high"
  alarm_description   = "ECS service ${each.value} memory utilization is above ${var.ecs_memory_high_threshold}%"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.ecs_memory_high_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "ecs-service-health"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_task_low" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-ecs-${each.value}-running-task-low"
  alarm_description   = "ECS service ${each.value} running task count dropped below ${var.ecs_running_task_minimum}"
  namespace           = "AWS/ECS"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = var.ecs_running_task_minimum
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "ecs-restart-alerting"
  }
}

resource "aws_cloudwatch_metric_alarm" "documentdb_cpu_high" {
  alarm_name          = "${local.name_prefix}-docdb-cpu-high"
  alarm_description   = "DocumentDB cluster CPU utilization is above ${var.documentdb_cpu_high_threshold}%"
  namespace           = "AWS/DocDB"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.documentdb_cpu_high_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.documentdb_cluster_identifier
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "documentdb-saturation"
  }
}

resource "aws_cloudwatch_metric_alarm" "documentdb_connections_high" {
  alarm_name          = "${local.name_prefix}-docdb-connections-high"
  alarm_description   = "DocumentDB cluster database connections exceed ${var.documentdb_connections_high_threshold}"
  namespace           = "AWS/DocDB"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.documentdb_connections_high_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.documentdb_cluster_identifier
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "documentdb-saturation"
  }
}

resource "aws_cloudwatch_metric_alarm" "documentdb_freeable_memory_low" {
  alarm_name          = "${local.name_prefix}-docdb-freeable-memory-low"
  alarm_description   = "DocumentDB cluster freeable memory is below threshold"
  namespace           = "AWS/DocDB"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = var.documentdb_freeable_memory_low_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.documentdb_cluster_identifier
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "documentdb-saturation"
  }
}

resource "aws_cloudwatch_metric_alarm" "amazonmq_cpu_high" {
  alarm_name          = "${local.name_prefix}-amazonmq-cpu-high"
  alarm_description   = "Amazon MQ broker CPU utilization is above ${var.amazonmq_cpu_high_threshold}%"
  namespace           = "AWS/AmazonMQ"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.amazonmq_cpu_high_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Broker = var.amazonmq_broker_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "amazonmq-saturation"
  }
}

resource "aws_cloudwatch_metric_alarm" "amazonmq_memory_used_high" {
  alarm_name          = "${local.name_prefix}-amazonmq-rabbitmq-memory-high"
  alarm_description   = "RabbitMQ broker memory usage is high"
  namespace           = "AWS/AmazonMQ"
  metric_name         = "RabbitMQMemUsed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.amazonmq_memory_used_high_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    Broker = var.amazonmq_broker_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "amazonmq-saturation"
  }
}

resource "aws_cloudwatch_metric_alarm" "amazonmq_disk_free_low" {
  alarm_name          = "${local.name_prefix}-amazonmq-rabbitmq-disk-free-low"
  alarm_description   = "RabbitMQ broker free disk space is low"
  namespace           = "AWS/AmazonMQ"
  metric_name         = "RabbitMQDiskFree"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = var.amazonmq_disk_free_low_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    Broker = var.amazonmq_broker_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Type        = "amazonmq-saturation"
  }
}

resource "aws_cloudwatch_dashboard" "core_services" {
  dashboard_name = "${local.name_prefix}-core-services"

  dashboard_body = jsonencode({
    widgets = [
      {
        "type" : "metric",
        "x" : 0,
        "y" : 0,
        "width" : 12,
        "height" : 6,
        "properties" : {
          "title" : "ECS CPU Utilization (%)",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : "${data.aws_region.current.name}",
          "period" : 60,
          "metrics" : local.ecs_cpu_metrics
        }
      },
      {
        "type" : "metric",
        "x" : 12,
        "y" : 0,
        "width" : 12,
        "height" : 6,
        "properties" : {
          "title" : "ECS Memory Utilization (%)",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : "${data.aws_region.current.name}",
          "period" : 60,
          "metrics" : local.ecs_memory_metrics
        }
      },
      {
        "type" : "metric",
        "x" : 0,
        "y" : 6,
        "width" : 12,
        "height" : 6,
        "properties" : {
          "title" : "ECS Running Task Count",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : "${data.aws_region.current.name}",
          "period" : 60,
          "metrics" : local.ecs_running_metrics
        }
      },
      {
        "type" : "metric",
        "x" : 12,
        "y" : 6,
        "width" : 12,
        "height" : 6,
        "properties" : {
          "title" : "DocumentDB and Amazon MQ Saturation",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : "${data.aws_region.current.name}",
          "period" : 60,
          "metrics" : [
            ["AWS/DocDB", "CPUUtilization", "DBClusterIdentifier", "${var.documentdb_cluster_identifier}", { "label" : "DocDB CPU %", "stat" : "Average" }],
            ["AWS/DocDB", "DatabaseConnections", "DBClusterIdentifier", "${var.documentdb_cluster_identifier}", { "label" : "DocDB Connections", "stat" : "Maximum" }],
            ["AWS/AmazonMQ", "CPUUtilization", "Broker", "${var.amazonmq_broker_name}", { "label" : "RabbitMQ CPU %", "stat" : "Average" }],
            ["AWS/AmazonMQ", "RabbitMQMemUsed", "Broker", "${var.amazonmq_broker_name}", { "label" : "RabbitMQ Memory Used (bytes)", "stat" : "Maximum" }],
            ["AWS/AmazonMQ", "RabbitMQDiskFree", "Broker", "${var.amazonmq_broker_name}", { "label" : "RabbitMQ Disk Free (bytes)", "stat" : "Minimum" }]
          ]
        }
      }
    ]
  })
}

data "aws_region" "current" {}