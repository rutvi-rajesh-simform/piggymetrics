terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region for CloudWatch and ECS resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project identifier used in names/tags."
  type        = string
  default     = "piggymetrics"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, stage, prod)."
  type        = string
  default     = "prod"
}

variable "ecs_cluster_name" {
  description = "ECS cluster name for application services."
  type        = string
  default     = "piggymetrics-cluster"
}

variable "ecs_service_names" {
  description = "ECS service names to monitor."
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

variable "log_retention_days" {
  description = "Retention period for ECS service log groups."
  type        = number
  default     = 30
}

variable "cpu_utilization_alarm_threshold" {
  description = "Alarm threshold for ECS service CPU utilization (%)."
  type        = number
  default     = 80
}

variable "memory_utilization_alarm_threshold" {
  description = "Alarm threshold for ECS service memory utilization (%)."
  type        = number
  default     = 80
}

variable "service_error_count_threshold" {
  description = "Alarm threshold for extracted ERROR log metric per service."
  type        = number
  default     = 20
}

variable "minimum_running_task_count" {
  description = "Minimum healthy running task count for each ECS service."
  type        = number
  default     = 1
}

variable "evaluation_periods" {
  description = "Number of periods over which data is compared to threshold."
  type        = number
  default     = 2
}

variable "period_seconds" {
  description = "CloudWatch metric period in seconds."
  type        = number
  default     = 60
}

variable "alarm_email_endpoint" {
  description = "Optional email endpoint for alarm notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "observability"
    },
    var.tags
  )

  log_group_names = [
    for svc in var.ecs_service_names : "/aws/ecs/${var.project_name}/${var.environment}/${svc}"
  ]

  logs_insights_query = format(
    "SOURCE %s | fields @timestamp, @log, @logStream, @message | filter @message like /ERROR|Exception|Timeout/ | sort @timestamp desc | limit 100",
    join(", ", [for lg in local.log_group_names : format("'%s'", lg)])
  )

  cpu_widget_metrics = [
    for svc in var.ecs_service_names : [
      "AWS/ECS",
      "CPUUtilization",
      "ClusterName",
      var.ecs_cluster_name,
      "ServiceName",
      svc,
      {
        stat  = "Average"
        label = "${svc} CPU %"
      }
    ]
  ]

  memory_widget_metrics = [
    for svc in var.ecs_service_names : [
      "AWS/ECS",
      "MemoryUtilization",
      "ClusterName",
      var.ecs_cluster_name,
      "ServiceName",
      svc,
      {
        stat  = "Average"
        label = "${svc} Memory %"
      }
    ]
  ]

  running_tasks_widget_metrics = [
    for svc in var.ecs_service_names : [
      "AWS/ECS",
      "RunningTaskCount",
      "ClusterName",
      var.ecs_cluster_name,
      "ServiceName",
      svc,
      {
        stat  = "Minimum"
        label = "${svc} Running Tasks"
      }
    ]
  ]
}

resource "aws_ecs_cluster" "this" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs_service" {
  for_each = toset(var.ecs_service_names)

  name              = "/aws/ecs/${var.project_name}/${var.environment}/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-cloudwatch-alarms"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email_endpoint != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email_endpoint
}

resource "aws_cloudwatch_log_metric_filter" "service_error_count" {
  for_each = aws_cloudwatch_log_group.ecs_service

  name           = "${local.name_prefix}-${each.key}-error-count"
  log_group_name = each.value.name
  pattern        = "?ERROR ?Exception ?Timeout ?5xx"

  metric_transformation {
    name      = "${replace(each.key, "-", "_")}_error_count"
    namespace = "${var.project_name}/${var.environment}/services"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-${each.value}-cpu-high"
  alarm_description   = "CPU utilization is high for ECS service ${each.value}."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = var.period_seconds
  evaluation_periods  = var.evaluation_periods
  threshold           = var.cpu_utilization_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-${each.value}-memory-high"
  alarm_description   = "Memory utilization is high for ECS service ${each.value}."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = var.period_seconds
  evaluation_periods  = var.evaluation_periods
  threshold           = var.memory_utilization_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "running_tasks_low" {
  for_each = toset(var.ecs_service_names)

  alarm_name          = "${local.name_prefix}-${each.value}-running-tasks-low"
  alarm_description   = "Running task count is below minimum for ECS service ${each.value}."
  namespace           = "AWS/ECS"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = var.period_seconds
  evaluation_periods  = var.evaluation_periods
  threshold           = var.minimum_running_task_count
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "service_error_count_high" {
  for_each = aws_cloudwatch_log_metric_filter.service_error_count

  alarm_name          = "${local.name_prefix}-${each.key}-error-count-high"
  alarm_description   = "Application error log volume is high for ECS service ${each.key}."
  namespace           = each.value.metric_transformation[0].namespace
  metric_name         = each.value.metric_transformation[0].name
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = var.evaluation_periods
  threshold           = var.service_error_count_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_dashboard" "ecs_observability" {
  dashboard_name = "${local.name_prefix}-ecs-observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# ${var.project_name} (${var.environment}) ECS Observability\nCloudWatch Logs + Metrics + Alarms + Container Insights"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          region  = var.aws_region
          title   = "ECS Service CPU Utilization (%)"
          view    = "timeSeries"
          stacked = false
          period  = var.period_seconds
          stat    = "Average"
          metrics = local.cpu_widget_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          region  = var.aws_region
          title   = "ECS Service Memory Utilization (%)"
          view    = "timeSeries"
          stacked = false
          period  = var.period_seconds
          stat    = "Average"
          metrics = local.memory_widget_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          region  = var.aws_region
          title   = "ECS Running Task Count"
          view    = "timeSeries"
          stacked = false
          period  = var.period_seconds
          stat    = "Minimum"
          metrics = local.running_tasks_widget_metrics
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title = "Alarm Status (CPU, Memory, Running Tasks, Error Logs)"
          alarms = concat(
            [for _, alarm in aws_cloudwatch_metric_alarm.cpu_high : alarm.arn],
            [for _, alarm in aws_cloudwatch_metric_alarm.memory_high : alarm.arn],
            [for _, alarm in aws_cloudwatch_metric_alarm.running_tasks_low : alarm.arn],
            [for _, alarm in aws_cloudwatch_metric_alarm.service_error_count_high : alarm.arn]
          )
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 14
        width  = 24
        height = 8
        properties = {
          region = var.aws_region
          title  = "Recent Error Logs Across ECS Services"
          view   = "table"
          query  = local.logs_insights_query
        }
      }
    ]
  })
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster with Container Insights enabled."
  value       = aws_ecs_cluster.this.arn
}

output "ecs_service_log_group_names" {
  description = "CloudWatch Log Group names for ECS services."
  value       = [for lg in aws_cloudwatch_log_group.ecs_service : lg.name]
}

output "cloudwatch_alarm_topic_arn" {
  description = "SNS topic ARN used by CloudWatch alarms."
  value       = aws_sns_topic.alarms.arn
}

output "cloudwatch_dashboard_name" {
  description = "Name of the ECS observability CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.ecs_observability.dashboard_name
}
