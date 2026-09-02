terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region for SES and related resources."
  type        = string
}

variable "project_name" {
  description = "Project name used for tagging and naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
}

variable "ses_domain" {
  description = "Verified SES domain identity (e.g., example.com)."
  type        = string
}

variable "ses_from_email" {
  description = "Optional mailbox identity to verify (e.g., no-reply@example.com)."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for ses_domain. Required when enable_route53_records is true."
  type        = string
  default     = ""
}

variable "enable_route53_records" {
  description = "Whether to create Route53 SES verification and DKIM records automatically."
  type        = bool
  default     = true
}

variable "create_smtp_user" {
  description = "Whether to create an IAM SMTP user and store credentials in Secrets Manager."
  type        = bool
  default     = true
}

variable "smtp_user_name" {
  description = "Optional explicit SMTP IAM username."
  type        = string
  default     = ""
}

variable "application_role_name" {
  description = "Optional IAM role name (for ECS task role or app role) to attach send-email policy."
  type        = string
  default     = ""
}

variable "allowed_from_addresses" {
  description = "Allowed sender addresses for policy conditions."
  type        = list(string)
  default     = ["*@example.com"]
}

variable "allowed_principal_arns" {
  description = "Optional external principal ARNs allowed by SES identity policy scaffolding."
  type        = list(string)
  default     = []
}

provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "ses"
  }

  computed_smtp_user_name = var.smtp_user_name != "" ? var.smtp_user_name : "${var.project_name}-${var.environment}-ses-smtp"

  create_dns_records = var.enable_route53_records && var.route53_zone_id != ""
}

resource "aws_ses_domain_identity" "domain" {
  domain = var.ses_domain
}

resource "aws_ses_domain_dkim" "domain" {
  domain = aws_ses_domain_identity.domain.domain
}

resource "aws_route53_record" "ses_verification" {
  count   = local.create_dns_records ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "_amazonses.${var.ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.domain.verification_token]
}

resource "aws_route53_record" "dkim" {
  for_each = local.create_dns_records ? toset(aws_ses_domain_dkim.domain.dkim_tokens) : toset([])

  zone_id = var.route53_zone_id
  name    = "${each.value}._domainkey.${var.ses_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${each.value}.dkim.amazonses.com"]
}

resource "aws_ses_domain_identity_verification" "domain" {
  count  = local.create_dns_records ? 1 : 0
  domain = aws_ses_domain_identity.domain.id

  depends_on = [
    aws_route53_record.ses_verification,
    aws_route53_record.dkim
  ]
}

resource "aws_ses_email_identity" "mailbox" {
  count = var.ses_from_email != "" ? 1 : 0
  email = var.ses_from_email
}

data "aws_iam_policy_document" "ses_identity_delegate" {
  count = length(var.allowed_principal_arns) > 0 ? 1 : 0

  statement {
    sid     = "AllowDelegatedSend"
    effect  = "Allow"
    actions = ["SES:SendEmail", "SES:SendRawEmail"]

    resources = [aws_ses_domain_identity.domain.arn]

    principals {
      type        = "AWS"
      identifiers = var.allowed_principal_arns
    }

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = var.allowed_from_addresses
    }
  }
}

resource "aws_ses_identity_policy" "delegate_send" {
  count    = length(var.allowed_principal_arns) > 0 ? 1 : 0
  identity = aws_ses_domain_identity.domain.domain
  name     = "${var.project_name}-${var.environment}-ses-delegate-send"
  policy   = data.aws_iam_policy_document.ses_identity_delegate[0].json
}

data "aws_iam_policy_document" "app_send_email" {
  statement {
    sid     = "AllowAppSendViaSes"
    effect  = "Allow"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [
      aws_ses_domain_identity.domain.arn
    ]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = var.allowed_from_addresses
    }
  }
}

resource "aws_iam_policy" "app_send_email" {
  name        = "${var.project_name}-${var.environment}-ses-send"
  description = "Allows application workloads to send email through SES."
  policy      = data.aws_iam_policy_document.app_send_email.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "app_send_email" {
  count      = var.application_role_name != "" ? 1 : 0
  role       = var.application_role_name
  policy_arn = aws_iam_policy.app_send_email.arn
}

resource "aws_iam_user" "smtp" {
  count = var.create_smtp_user ? 1 : 0
  name  = local.computed_smtp_user_name
  tags  = local.tags
}

data "aws_iam_policy_document" "smtp_send" {
  count = var.create_smtp_user ? 1 : 0

  statement {
    sid     = "AllowSmtpSendRawEmail"
    effect  = "Allow"
    actions = ["ses:SendRawEmail"]
    resources = [
      "*"
    ]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = var.allowed_from_addresses
    }
  }
}

resource "aws_iam_user_policy" "smtp_send" {
  count  = var.create_smtp_user ? 1 : 0
  name   = "${local.computed_smtp_user_name}-send"
  user   = aws_iam_user.smtp[0].name
  policy = data.aws_iam_policy_document.smtp_send[0].json
}

resource "aws_iam_access_key" "smtp" {
  count = var.create_smtp_user ? 1 : 0
  user  = aws_iam_user.smtp[0].name
}

resource "aws_secretsmanager_secret" "smtp_credentials" {
  count       = var.create_smtp_user ? 1 : 0
  name        = "${var.project_name}/${var.environment}/ses/smtp"
  description = "SES SMTP credentials for application mail transport"

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "smtp_credentials" {
  count     = var.create_smtp_user ? 1 : 0
  secret_id = aws_secretsmanager_secret.smtp_credentials[0].id

  secret_string = jsonencode({
    username  = aws_iam_access_key.smtp[0].id
    password  = aws_iam_access_key.smtp[0].ses_smtp_password_v4
    host      = "email-smtp.${var.aws_region}.amazonaws.com"
    port      = 587
    tls       = true
    region    = var.aws_region
    identity  = var.ses_domain
    fromEmail = var.ses_from_email
  })
}

output "ses_domain_identity_arn" {
  description = "ARN of the SES domain identity."
  value       = aws_ses_domain_identity.domain.arn
}

output "ses_domain_verification_token" {
  description = "SES TXT verification token for external DNS workflows."
  value       = aws_ses_domain_identity.domain.verification_token
}

output "ses_dkim_tokens" {
  description = "DKIM tokens for external DNS workflows."
  value       = aws_ses_domain_dkim.domain.dkim_tokens
}

output "ses_send_policy_arn" {
  description = "IAM policy ARN that grants ses:SendEmail and ses:SendRawEmail."
  value       = aws_iam_policy.app_send_email.arn
}

output "smtp_secret_arn" {
  description = "Secrets Manager secret ARN containing SMTP credentials."
  value       = var.create_smtp_user ? aws_secretsmanager_secret.smtp_credentials[0].arn : null
}

output "smtp_username" {
  description = "SMTP username (IAM access key id)."
  value       = var.create_smtp_user ? aws_iam_access_key.smtp[0].id : null
  sensitive   = true
}

output "smtp_password" {
  description = "SMTP password derived from IAM secret access key (SES v4)."
  value       = var.create_smtp_user ? aws_iam_access_key.smtp[0].ses_smtp_password_v4 : null
  sensitive   = true
}