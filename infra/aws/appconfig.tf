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
  description = "AWS region for AppConfig resources."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to AppConfig resource names."
  type        = string
  default     = "piggymetrics"
}

variable "deploy_initial_to_dev" {
  description = "Whether to deploy initial hosted configuration versions to the dev environment."
  type        = bool
  default     = true
}

variable "environment_alarm_arns" {
  description = "Optional CloudWatch alarm ARNs per environment to enable automatic rollback (e.g., { dev = [\"arn:aws:cloudwatch:...:alarm:my-alarm\"], prod = [...] })."
  type        = map(list(string))
  default = {
    dev  = []
    prod = []
  }
}

variable "tags" {
  description = "Tags applied to all AppConfig resources."
  type        = map(string)
  default = {
    Project = "PiggyMetrics"
    Managed = "terraform"
  }
}

locals {
  app_name = "${var.name_prefix}-shared-config"

  notification_schedules_content = jsonencode({
    remind = {
      cron = "0 0 0 * * *"
      email = {
        subject = "PiggyMetrics reminder"
        text    = "Hey, {0}! We've missed you here on PiggyMetrics. It's time to check your budget statistics.\\r\\n\\r\\nCheers,\\r\\nPiggyMetrics team"
      }
    }
    backup = {
      cron = "0 0 12 * * *"
      email = {
        subject    = "PiggyMetrics account backup"
        text       = "Howdy, {0}. Your account backup is ready.\\r\\n\\r\\nCheers,\\r\\nPiggyMetrics team"
        attachment = "backup.json"
      }
    }
  })

  gateway_routing_content = jsonencode({
    zuul = {
      routes = {
        auth_service = {
          path         = "/uaa/**"
          url          = "http://auth-service:5000"
          strip_prefix = false
        }
        account_service = {
          path         = "/accounts/**"
          service_id   = "account-service"
          strip_prefix = false
        }
        statistics_service = {
          path         = "/statistics/**"
          service_id   = "statistics-service"
          strip_prefix = false
        }
        notification_service = {
          path         = "/notifications/**"
          service_id   = "notification-service"
          strip_prefix = false
        }
      }
    }
  })

  notification_schedules_schema = jsonencode({
    "$schema" = "https://json-schema.org/draft/2020-12/schema"
    type       = "object"
    required   = ["remind", "backup"]
    properties = {
      remind = {
        type     = "object"
        required = ["cron", "email"]
        properties = {
          cron = { type = "string", minLength = 1 }
          email = {
            type     = "object"
            required = ["subject", "text"]
            properties = {
              subject = { type = "string", minLength = 1 }
              text    = { type = "string", minLength = 1 }
            }
            additionalProperties = true
          }
        }
        additionalProperties = true
      }
      backup = {
        type     = "object"
        required = ["cron", "email"]
        properties = {
          cron = { type = "string", minLength = 1 }
          email = {
            type     = "object"
            required = ["subject", "text", "attachment"]
            properties = {
              subject    = { type = "string", minLength = 1 }
              text       = { type = "string", minLength = 1 }
              attachment = { type = "string", minLength = 1 }
            }
            additionalProperties = true
          }
        }
        additionalProperties = true
      }
    }
    additionalProperties = false
  })

  gateway_routing_schema = jsonencode({
    "$schema" = "https://json-schema.org/draft/2020-12/schema"
    type       = "object"
    required   = ["zuul"]
    properties = {
      zuul = {
        type     = "object"
        required = ["routes"]
        properties = {
          routes = {
            type = "object"
            properties = {
              auth_service = {
                type     = "object"
                required = ["path", "strip_prefix"]
                properties = {
                  path         = { type = "string", minLength = 1 }
                  url          = { type = "string" }
                  service_id   = { type = "string" }
                  strip_prefix = { type = "boolean" }
                }
                additionalProperties = true
              }
              account_service = {
                type     = "object"
                required = ["path", "service_id", "strip_prefix"]
                properties = {
                  path         = { type = "string", minLength = 1 }
                  service_id   = { type = "string", minLength = 1 }
                  strip_prefix = { type = "boolean" }
                }
                additionalProperties = true
              }
              statistics_service = {
                type     = "object"
                required = ["path", "service_id", "strip_prefix"]
                properties = {
                  path         = { type = "string", minLength = 1 }
                  service_id   = { type = "string", minLength = 1 }
                  strip_prefix = { type = "boolean" }
                }
                additionalProperties = true
              }
              notification_service = {
                type     = "object"
                required = ["path", "service_id", "strip_prefix"]
                properties = {
                  path         = { type = "string", minLength = 1 }
                  service_id   = { type = "string", minLength = 1 }
                  strip_prefix = { type = "boolean" }
                }
                additionalProperties = true
              }
            }
            additionalProperties = true
          }
        }
        additionalProperties = true
      }
    }
    additionalProperties = false
  })
}

resource "aws_appconfig_application" "shared" {
  name        = local.app_name
  description = "Centralized shared runtime configuration for PiggyMetrics microservices"
  tags        = var.tags
}

resource "aws_appconfig_environment" "dev" {
  application_id = aws_appconfig_application.shared.id
  name           = "dev"
  description    = "Development environment for configuration rollout"

  dynamic "monitor" {
    for_each = toset(lookup(var.environment_alarm_arns, "dev", []))
    content {
      alarm_arn      = monitor.value
      alarm_role_arn = null
    }
  }

  tags = var.tags
}

resource "aws_appconfig_environment" "prod" {
  application_id = aws_appconfig_application.shared.id
  name           = "prod"
  description    = "Production environment for staged and validated configuration deployment"

  dynamic "monitor" {
    for_each = toset(lookup(var.environment_alarm_arns, "prod", []))
    content {
      alarm_arn      = monitor.value
      alarm_role_arn = null
    }
  }

  tags = var.tags
}

resource "aws_appconfig_deployment_strategy" "progressive_with_bake" {
  name                           = "${var.name_prefix}-progressive-20pct-30min"
  description                    = "Linear 20% rollout over 30 minutes with bake time for safe rollback"
  deployment_duration_in_minutes = 30
  final_bake_time_in_minutes     = 10
  growth_factor                  = 20
  growth_type                    = "LINEAR"
  replicate_to                   = "NONE"
  tags                           = var.tags
}

resource "aws_appconfig_configuration_profile" "notification_schedules" {
  application_id = aws_appconfig_application.shared.id
  name           = "notification-schedules"
  location_uri   = "hosted"
  description    = "Validated reminder and backup schedule configuration for notification-service"
  type           = "AWS.Freeform"

  validator {
    type    = "JSON_SCHEMA"
    content = local.notification_schedules_schema
  }

  tags = var.tags
}

resource "aws_appconfig_configuration_profile" "gateway_routing" {
  application_id = aws_appconfig_application.shared.id
  name           = "gateway-routing"
  location_uri   = "hosted"
  description    = "Validated gateway route mapping and service endpoint configuration"
  type           = "AWS.Freeform"

  validator {
    type    = "JSON_SCHEMA"
    content = local.gateway_routing_schema
  }

  tags = var.tags
}

resource "aws_appconfig_hosted_configuration_version" "notification_schedules_v1" {
  application_id           = aws_appconfig_application.shared.id
  configuration_profile_id = aws_appconfig_configuration_profile.notification_schedules.configuration_profile_id
  content_type             = "application/json"
  description              = "Initial notification schedule baseline"
  content                  = local.notification_schedules_content
}

resource "aws_appconfig_hosted_configuration_version" "gateway_routing_v1" {
  application_id           = aws_appconfig_application.shared.id
  configuration_profile_id = aws_appconfig_configuration_profile.gateway_routing.configuration_profile_id
  content_type             = "application/json"
  description              = "Initial gateway routing baseline"
  content                  = local.gateway_routing_content
}

resource "aws_appconfig_deployment" "notification_schedules_dev" {
  count = var.deploy_initial_to_dev ? 1 : 0

  application_id           = aws_appconfig_application.shared.id
  environment_id           = aws_appconfig_environment.dev.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.notification_schedules.configuration_profile_id
  configuration_version    = tostring(aws_appconfig_hosted_configuration_version.notification_schedules_v1.version_number)
  deployment_strategy_id   = aws_appconfig_deployment_strategy.progressive_with_bake.id
  description              = "Initial dev deployment for notification schedule config"

  tags = var.tags
}

resource "aws_appconfig_deployment" "gateway_routing_dev" {
  count = var.deploy_initial_to_dev ? 1 : 0

  application_id           = aws_appconfig_application.shared.id
  environment_id           = aws_appconfig_environment.dev.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.gateway_routing.configuration_profile_id
  configuration_version    = tostring(aws_appconfig_hosted_configuration_version.gateway_routing_v1.version_number)
  deployment_strategy_id   = aws_appconfig_deployment_strategy.progressive_with_bake.id
  description              = "Initial dev deployment for gateway routing config"

  tags = var.tags
}
