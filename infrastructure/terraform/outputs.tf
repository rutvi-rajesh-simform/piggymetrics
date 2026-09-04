output "documentdb_endpoint" {
  description = "Amazon DocumentDB cluster writer endpoint"
  value       = aws_docdb_cluster.main.endpoint
}

output "documentdb_reader_endpoint" {
  description = "Amazon DocumentDB cluster reader endpoint"
  value       = aws_docdb_cluster.main.reader_endpoint
}

output "sqs_queue_urls" {
  description = "Map of SQS queue URLs keyed by queue logical name"
  value       = { for name, queue in aws_sqs_queue.queues : name => queue.id }
}

output "sqs_queue_arns" {
  description = "Map of SQS queue ARNs keyed by queue logical name"
  value       = { for name, queue in aws_sqs_queue.queues : name => queue.arn }
}

output "sns_topic_arns" {
  description = "Map of SNS topic ARNs keyed by topic logical name"
  value       = { for name, topic in aws_sns_topic.topics : name => topic.arn }
}

output "appconfig_application_id" {
  description = "AWS AppConfig application ID"
  value       = aws_appconfig_application.main.id
}

output "appconfig_environment_id" {
  description = "AWS AppConfig environment ID"
  value       = aws_appconfig_environment.main.environment_id
}

output "appconfig_configuration_profile_id" {
  description = "AWS AppConfig configuration profile ID"
  value       = aws_appconfig_configuration_profile.main.configuration_profile_id
}

output "api_gateway_endpoint" {
  description = "Invoke URL for the deployed API Gateway stage"
  value       = aws_apigatewayv2_stage.main.invoke_url
}