terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "project_name" {
  description = "Project or application name used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all messaging resources."
  type        = map(string)
  default     = {}
}

variable "sns_topics" {
  description = "SNS topics that replace RabbitMQ exchanges/fanout channels."
  type = map(object({
    fifo                        = optional(bool, false)
    content_based_deduplication = optional(bool, true)
  }))

  default = {
    domain_events = {}
    notifications = {}
  }
}

variable "sqs_queues" {
  description = "SQS queues that replace RabbitMQ queues, with optional DLQ and SNS subscriptions."
  type = map(object({
    fifo                        = optional(bool, false)
    content_based_deduplication = optional(bool, true)
    visibility_timeout_seconds  = optional(number, 60)
    message_retention_seconds   = optional(number, 345600)
    max_message_size            = optional(number, 262144)
    max_receive_count           = optional(number, 5)
    dlq_enabled                 = optional(bool, true)
    subscribe_to_topics         = optional(list(string), [])
  }))

  default = {
    orders_worker = {
      subscribe_to_topics = ["domain_events"]
    }
    billing_worker = {
      subscribe_to_topics = ["domain_events"]
    }
    notification_worker = {
      subscribe_to_topics = ["notifications"]
    }
  }
}

locals {
  default_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "messaging"
  })

  sns_topic_config = {
    for key, value in var.sns_topics :
    key => merge({
      fifo                        = false
      content_based_deduplication = true
    }, value)
  }

  sqs_queue_config = {
    for key, value in var.sqs_queues :
    key => merge({
      fifo                        = false
      content_based_deduplication = true
      visibility_timeout_seconds  = 60
      message_retention_seconds   = 345600
      max_message_size            = 262144
      max_receive_count           = 5
      dlq_enabled                 = true
      subscribe_to_topics         = []
    }, value)
  }

  queue_topic_pairs = flatten([
    for queue_key, queue_cfg in local.sqs_queue_config : [
      for topic_key in queue_cfg.subscribe_to_topics : {
        queue_key = queue_key
        topic_key = topic_key
      }
    ]
  ])

  subscriptions = {
    for pair in local.queue_topic_pairs :
    "${pair.queue_key}:${pair.topic_key}" => pair
    if contains(keys(local.sns_topic_config), pair.topic_key)
  }

  queue_policy_topic_arns = {
    for queue_key, queue_cfg in local.sqs_queue_config :
    queue_key => [
      for topic_key in queue_cfg.subscribe_to_topics : aws_sns_topic.this[topic_key].arn
      if contains(keys(aws_sns_topic.this), topic_key)
    ]
  }

  queue_policy_topic_arns_filtered = {
    for queue_key, arns in local.queue_policy_topic_arns :
    queue_key => arns
    if length(arns) > 0
  }
}

resource "aws_sns_topic" "this" {
  for_each = local.sns_topic_config

  name                        = "${var.project_name}-${var.environment}-${each.key}${each.value.fifo ? ".fifo" : ""}"
  fifo_topic                  = each.value.fifo
  content_based_deduplication = each.value.fifo ? each.value.content_based_deduplication : null

  tags = local.default_tags
}

resource "aws_sqs_queue" "dlq" {
  for_each = {
    for queue_key, queue_cfg in local.sqs_queue_config :
    queue_key => queue_cfg
    if queue_cfg.dlq_enabled
  }

  name                        = "${var.project_name}-${var.environment}-${each.key}-dlq${each.value.fifo ? ".fifo" : ""}"
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo ? each.value.content_based_deduplication : null
  message_retention_seconds   = 1209600
  sqs_managed_sse_enabled     = true

  tags = merge(local.default_tags, { Role = "dlq" })
}

resource "aws_sqs_queue" "this" {
  for_each = local.sqs_queue_config

  name                        = "${var.project_name}-${var.environment}-${each.key}${each.value.fifo ? ".fifo" : ""}"
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo ? each.value.content_based_deduplication : null
  visibility_timeout_seconds  = each.value.visibility_timeout_seconds
  message_retention_seconds   = each.value.message_retention_seconds
  max_message_size            = each.value.max_message_size
  sqs_managed_sse_enabled     = true

  redrive_policy = each.value.dlq_enabled ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  }) : null

  tags = merge(local.default_tags, { Role = "primary" })
}

resource "aws_sns_topic_subscription" "sqs" {
  for_each = local.subscriptions

  topic_arn            = aws_sns_topic.this[each.value.topic_key].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.this[each.value.queue_key].arn
  raw_message_delivery = true
}

data "aws_iam_policy_document" "allow_sns_to_sqs" {
  for_each = local.queue_policy_topic_arns_filtered

  dynamic "statement" {
    for_each = each.value
    content {
      sid    = "AllowSNS${replace(replace(statement.value, ":", ""), "/", "")}" 
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["sns.amazonaws.com"]
      }

      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.this[each.key].arn]

      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [statement.value]
      }
    }
  }
}

resource "aws_sqs_queue_policy" "allow_sns" {
  for_each = local.queue_policy_topic_arns_filtered

  queue_url = aws_sqs_queue.this[each.key].id
  policy    = data.aws_iam_policy_document.allow_sns_to_sqs[each.key].json
}

output "sns_topic_arns" {
  description = "ARNs for provisioned SNS topics."
  value       = { for key, topic in aws_sns_topic.this : key => topic.arn }
}

output "sqs_queue_urls" {
  description = "URLs for provisioned SQS queues."
  value       = { for key, queue in aws_sqs_queue.this : key => queue.id }
}

output "sqs_dlq_urls" {
  description = "URLs for provisioned DLQs."
  value       = { for key, queue in aws_sqs_queue.dlq : key => queue.id }
}