data "aws_region" "current" {}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster running the application services."
  value       = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster for deployment and service discovery configuration."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_arn" {
  description = "ARN of the primary ECS service deployed on Fargate."
  value       = aws_ecs_service.main.arn
}

output "ecs_service_name" {
  description = "Name of the primary ECS service deployed on Fargate."
  value       = aws_ecs_service.main.name
}

output "ecs_task_definition_arn" {
  description = "Latest ECS task definition ARN used by the service."
  value       = aws_ecs_task_definition.main.arn
}

output "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace ID used for internal service discovery."
  value       = aws_service_discovery_private_dns_namespace.main.id
}

output "service_discovery_namespace_arn" {
  description = "Cloud Map private DNS namespace ARN."
  value       = aws_service_discovery_private_dns_namespace.main.arn
}

output "service_discovery_namespace_name" {
  description = "Cloud Map private DNS namespace name for application bootstrap config."
  value       = aws_service_discovery_private_dns_namespace.main.name
}

output "service_discovery_service_arn" {
  description = "Cloud Map service ARN registered by ECS services."
  value       = aws_service_discovery_service.main.arn
}

output "service_discovery_service_id" {
  description = "Cloud Map service ID used in deployment hooks and service registration checks."
  value       = aws_service_discovery_service.main.id
}

output "documentdb_cluster_arn" {
  description = "ARN of the Amazon DocumentDB cluster."
  value       = aws_docdb_cluster.main.arn
}

output "documentdb_cluster_endpoint" {
  description = "Primary endpoint of the Amazon DocumentDB cluster for application writes."
  value       = aws_docdb_cluster.main.endpoint
}

output "documentdb_reader_endpoint" {
  description = "Reader endpoint of the Amazon DocumentDB cluster for read scaling."
  value       = aws_docdb_cluster.main.reader_endpoint
}

output "documentdb_port" {
  description = "Port exposed by the Amazon DocumentDB cluster."
  value       = aws_docdb_cluster.main.port
}

output "rabbitmq_broker_arn" {
  description = "ARN of the Amazon MQ RabbitMQ broker."
  value       = aws_mq_broker.main.arn
}

output "rabbitmq_broker_id" {
  description = "Broker ID of the Amazon MQ RabbitMQ instance."
  value       = aws_mq_broker.main.id
}

output "rabbitmq_console_url" {
  description = "Web console URL for RabbitMQ management."
  value       = aws_mq_broker.main.instances[0].console_url
}

output "rabbitmq_amqps_endpoint" {
  description = "AMQPS endpoint used by services and CI smoke tests."
  value       = aws_mq_broker.main.instances[0].endpoints[0]
}

output "ses_domain_identity_arn" {
  description = "ARN of the SES domain identity used for verified sender configuration."
  value       = aws_ses_domain_identity.main.arn
}

output "ses_domain" {
  description = "Verified SES sending domain."
  value       = aws_ses_domain_identity.main.domain
}

output "ses_smtp_endpoint" {
  description = "Regional SES SMTP endpoint for application mail transport configuration."
  value       = "email-smtp.${data.aws_region.current.name}.amazonaws.com"
}