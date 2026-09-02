terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for Secrets Manager resources"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Project/application prefix used in resource names"
  type        = string
  default     = "piggymetrics"
}

variable "environment" {
  description = "Deployment environment name (e.g., dev, stage, prod)"
  type        = string
  default     = "dev"
}

variable "ecs_task_role_names" {
  description = "List of ECS task IAM role names that need runtime access to secrets"
  type        = list(string)
  default     = ["piggymetrics-ecs-task-role"]
}

variable "documentdb_username" {
  description = "DocumentDB username"
  type        = string
  sensitive   = true
}

variable "documentdb_password" {
  description = "DocumentDB password"
  type        = string
  sensitive   = true
}

variable "documentdb_host" {
  description = "DocumentDB endpoint hostname"
  type        = string
}

variable "documentdb_port" {
  description = "DocumentDB port"
  type        = number
  default     = 27017
}

variable "documentdb_database" {
  description = "DocumentDB database name"
  type        = string
  default     = "piggymetrics"
}

variable "ses_smtp_username" {
  description = "SES SMTP username"
  type        = string
  sensitive   = true
}

variable "ses_smtp_password" {
  description = "SES SMTP password"
  type        = string
  sensitive   = true
}

variable "ses_smtp_host" {
  description = "SMTP endpoint host used by notification service"
  type        = string
  default     = ""
}

variable "ses_smtp_port" {
  description = "SMTP endpoint port"
  type        = number
  default     = 465
}

variable "config_service_password" {
  description = "OAuth client secret for config service"
  type        = string
  sensitive   = true
}

variable "notification_service_password" {
  description = "OAuth client secret for notification service"
  type        = string
  sensitive   = true
}

variable "statistics_service_password" {
  description = "OAuth client secret for statistics service"
  type        = string
  sensitive   = true
}

variable "account_service_password" {
  description = "OAuth client secret for account service"
  type        = string
  sensitive   = true
}

variable "mongodb_password" {
  description = "Shared MongoDB/DocumentDB password used by services"
  type        = string
  sensitive   = true
}

locals {
  ses_effective_host = var.ses_smtp_host != "" ? var.ses_smtp_host : "email-smtp.${var.aws_region}.amazonaws.com"

  common_tags = {
    Project     = var.name_prefix
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "secrets-manager"
  }
}

resource "aws_secretsmanager_secret" "documentdb_credentials" {
  name                    = "${var.name_prefix}/${var.environment}/documentdb/credentials"
  description             = "Runtime DocumentDB credentials for ECS tasks"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "documentdb_credentials" {
  secret_id = aws_secretsmanager_secret.documentdb_credentials.id

  secret_string = jsonencode({
    username = var.documentdb_username
    password = var.documentdb_password
    host     = var.documentdb_host
    port     = var.documentdb_port
    database = var.documentdb_database
  })
}

resource "aws_secretsmanager_secret" "ses_smtp_credentials" {
  name                    = "${var.name_prefix}/${var.environment}/ses/smtp"
  description             = "SMTP credentials for notification service"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "ses_smtp_credentials" {
  secret_id = aws_secretsmanager_secret.ses_smtp_credentials.id

  secret_string = jsonencode({
    username = var.ses_smtp_username
    password = var.ses_smtp_password
    host     = local.ses_effective_host
    port     = var.ses_smtp_port
  })
}

resource "aws_secretsmanager_secret" "service_passwords" {
  name                    = "${var.name_prefix}/${var.environment}/services/passwords"
  description             = "Centralized service passwords migrated from .env/static YAML"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "service_passwords" {
  secret_id = aws_secretsmanager_secret.service_passwords.id

  secret_string = jsonencode({
    CONFIG_SERVICE_PASSWORD       = var.config_service_password
    NOTIFICATION_SERVICE_PASSWORD = var.notification_service_password
    STATISTICS_SERVICE_PASSWORD   = var.statistics_service_password
    ACCOUNT_SERVICE_PASSWORD      = var.account_service_password
    MONGODB_PASSWORD              = var.mongodb_password
  })
}

data "aws_iam_policy_document" "ecs_secrets_access" {
  statement {
    sid    = "AllowReadApplicationSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]

    resources = [
      aws_secretsmanager_secret.documentdb_credentials.arn,
      aws_secretsmanager_secret.ses_smtp_credentials.arn,
      aws_secretsmanager_secret.service_passwords.arn
    ]
  }
}

resource "aws_iam_policy" "ecs_secrets_access" {
  name        = "${var.name_prefix}-${var.environment}-ecs-secrets-access"
  description = "Allow ECS tasks to retrieve runtime secrets from AWS Secrets Manager"
  policy      = data.aws_iam_policy_document.ecs_secrets_access.json

  tags = local.common_tags
}

data "aws_iam_role" "ecs_task_roles" {
  for_each = toset(var.ecs_task_role_names)
  name     = each.value
}

resource "aws_iam_role_policy_attachment" "ecs_task_secrets_access" {
  for_each = data.aws_iam_role.ecs_task_roles

  role       = each.value.name
  policy_arn = aws_iam_policy.ecs_secrets_access.arn
}

output "documentdb_secret_name" {
  description = "Secrets Manager name for DocumentDB credentials"
  value       = aws_secretsmanager_secret.documentdb_credentials.name
}

output "ses_smtp_secret_name" {
  description = "Secrets Manager name for SES SMTP credentials"
  value       = aws_secretsmanager_secret.ses_smtp_credentials.name
}

output "service_passwords_secret_name" {
  description = "Secrets Manager name for centralized service passwords"
  value       = aws_secretsmanager_secret.service_passwords.name
}
