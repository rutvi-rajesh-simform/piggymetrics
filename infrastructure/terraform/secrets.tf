terraform {
  required_version = ">= 1.4.0"

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
  description = "AWS region where secrets and IAM policies are created."
  type        = string
}

variable "project_name" {
  description = "Project/workload name used in secret naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, stage, prod) used in secret naming."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to created resources."
  type        = map(string)
  default     = {}
}

variable "ecs_task_role_arns" {
  description = "List of ECS task role ARNs that require read access to the secrets."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for Secrets Manager encryption. If null, AWS managed key is used."
  type        = string
  default     = null
}

variable "documentdb_username" {
  description = "DocumentDB username stored in Secrets Manager."
  type        = string
  sensitive   = true
}

variable "documentdb_password" {
  description = "DocumentDB password stored in Secrets Manager."
  type        = string
  sensitive   = true
}

variable "documentdb_host" {
  description = "DocumentDB endpoint/host stored in Secrets Manager."
  type        = string
}

variable "documentdb_port" {
  description = "DocumentDB port stored in Secrets Manager."
  type        = number
  default     = 27017
}

variable "documentdb_database" {
  description = "Default DocumentDB database name stored in Secrets Manager."
  type        = string
}

variable "smtp_host" {
  description = "SMTP server host stored in Secrets Manager."
  type        = string
}

variable "smtp_port" {
  description = "SMTP server port stored in Secrets Manager."
  type        = number
}

variable "smtp_username" {
  description = "SMTP username stored in Secrets Manager."
  type        = string
  sensitive   = true
}

variable "smtp_password" {
  description = "SMTP password stored in Secrets Manager."
  type        = string
  sensitive   = true
}

variable "smtp_from_address" {
  description = "Default SMTP from-address stored in Secrets Manager."
  type        = string
}

variable "oauth_client_secrets" {
  description = "Map of OAuth client IDs to client secrets. Example: { \"account-service\" = \"...\", \"statistics-service\" = \"...\" }"
  type        = map(string)
  sensitive   = true
}

locals {
  secret_prefix = "/${var.project_name}/${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Component   = "secrets"
    },
    var.tags
  )

  ecs_task_role_names = toset([
    for arn in var.ecs_task_role_arns : element(reverse(split("/", arn)), 0)
  ])
}

resource "aws_secretsmanager_secret" "documentdb_credentials" {
  name                    = "${local.secret_prefix}/documentdb/credentials"
  description             = "DocumentDB credentials and connection details for ${var.project_name}-${var.environment}."
  kms_key_id              = var.kms_key_arn
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

resource "aws_secretsmanager_secret" "smtp_credentials" {
  name                    = "${local.secret_prefix}/smtp/credentials"
  description             = "SMTP credentials for ${var.project_name}-${var.environment}."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "smtp_credentials" {
  secret_id = aws_secretsmanager_secret.smtp_credentials.id
  secret_string = jsonencode({
    host         = var.smtp_host
    port         = var.smtp_port
    username     = var.smtp_username
    password     = var.smtp_password
    from_address = var.smtp_from_address
  })
}

resource "aws_secretsmanager_secret" "oauth_client_secrets" {
  name                    = "${local.secret_prefix}/oauth/client-secrets"
  description             = "OAuth client secrets for internal service-to-service authentication in ${var.project_name}-${var.environment}."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "oauth_client_secrets" {
  secret_id     = aws_secretsmanager_secret.oauth_client_secrets.id
  secret_string = jsonencode(var.oauth_client_secrets)
}

data "aws_iam_policy_document" "ecs_task_secrets_access" {
  statement {
    sid    = "AllowReadProjectSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]

    resources = [
      aws_secretsmanager_secret.documentdb_credentials.arn,
      aws_secretsmanager_secret.smtp_credentials.arn,
      aws_secretsmanager_secret.oauth_client_secrets.arn
    ]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]

    content {
      sid    = "AllowDecryptSecretsKey"
      effect = "Allow"

      actions = [
        "kms:Decrypt"
      ]

      resources = [
        statement.value
      ]
    }
  }
}

resource "aws_iam_role_policy" "ecs_task_secrets_access" {
  for_each = local.ecs_task_role_names

  name   = "${var.project_name}-${var.environment}-secrets-access"
  role   = each.value
  policy = data.aws_iam_policy_document.ecs_task_secrets_access.json
}

output "secrets_manager_secret_arns" {
  description = "Secret ARNs for application integration (inject into ECS task definitions as needed)."
  value = {
    documentdb_credentials = aws_secretsmanager_secret.documentdb_credentials.arn
    smtp_credentials       = aws_secretsmanager_secret.smtp_credentials.arn
    oauth_client_secrets   = aws_secretsmanager_secret.oauth_client_secrets.arn
  }
  sensitive = true
}
