variable "environment" {
  description = "Deployment environment name (e.g., dev, staging, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region where infrastructure will be deployed."
  type        = string
}

variable "broker_endpoints" {
  description = "List of RabbitMQ broker endpoints used by the application."
  type        = list(string)
  default     = []
}

variable "broker_port" {
  description = "RabbitMQ broker port."
  type        = number
  default     = 5671
}

variable "service_discovery_namespace_id" {
  description = "AWS Cloud Map private DNS namespace ID used for service discovery."
  type        = string
  default     = ""
}

variable "service_discovery_service_name" {
  description = "Cloud Map service name registered for the broker/application service."
  type        = string
  default     = ""
}

variable "documentdb_cluster_endpoint" {
  description = "Amazon DocumentDB cluster endpoint (without mongodb:// prefix)."
  type        = string
}

variable "documentdb_port" {
  description = "Amazon DocumentDB port."
  type        = number
  default     = 27017
}

variable "documentdb_database_name" {
  description = "Logical DocumentDB database name used by the service."
  type        = string
}

variable "documentdb_username" {
  description = "Master/application username for DocumentDB authentication."
  type        = string
  sensitive   = true
}

variable "documentdb_password" {
  description = "Master/application password for DocumentDB authentication."
  type        = string
  sensitive   = true
}

variable "documentdb_tls_enabled" {
  description = "Whether TLS is required for DocumentDB connections."
  type        = bool
  default     = true
}

variable "ses_from_email" {
  description = "Default verified SES sender email address (From)."
  type        = string
}

variable "ses_reply_to_email" {
  description = "Optional default Reply-To email address for SES messages."
  type        = string
  default     = ""
}

variable "ses_identity_arns" {
  description = "List of verified SES identity ARNs (domains/emails) allowed for sending."
  type        = list(string)
  default     = []
}

variable "vpc_id" {
  description = "VPC ID where ECS, MQ, and DocumentDB workloads run."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks and stateful services."
  type        = list(string)
}

variable "ecs_service_security_group_ids" {
  description = "Security group IDs attached to ECS tasks/services."
  type        = list(string)
  default     = []
}

variable "ecs_task_cpu" {
  description = "ECS task CPU units (e.g., 256, 512, 1024)."
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "ECS task memory in MiB (e.g., 1024, 2048)."
  type        = number
  default     = 1024
}

variable "ecs_desired_count" {
  description = "Desired number of ECS tasks to run."
  type        = number
  default     = 2
}

variable "ecs_min_capacity" {
  description = "Minimum ECS service task count for auto scaling."
  type        = number
  default     = 1
}

variable "ecs_max_capacity" {
  description = "Maximum ECS service task count for auto scaling."
  type        = number
  default     = 4
}

variable "ecs_container_port" {
  description = "Application container port exposed by the ECS task."
  type        = number
  default     = 8080
}

variable "common_tags" {
  description = "Common tags applied to all AWS resources."
  type        = map(string)
  default     = {}
}