terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  app_name = "spring-cloud-config-replacement"

  common_tags = {
    ManagedBy   = "terraform"
    Service     = "appconfig"
    Replacement = "spring-cloud-config"
  }

  environments = {
    dev = {
      description = "Development environment"
    }
    staging = {
      description = "Staging environment"
    }
    prod = {
      description = "Production environment"
    }
  }

  configuration_profiles = {
    shared = {
      name         = "shared-config"
      description  = "Common application properties shared across services"
      content_type = "application/x-yaml"
    }
    service = {
      name         = "service-config"
      description  = "Service-specific runtime properties"
      content_type = "application/x-yaml"
    }
  }

  profile_contents = {
    shared = <<-YAML
      app:
        name: sample-service
        config_source: aws-appconfig
      logging:
        level:
          root: INFO
      management:
        endpoints:
          web:
            exposure:
              include: health,info
    YAML

    service = <<-YAML
      featureFlags:
        checkoutV2: false
      queues:
        orderEvents: "orders-events"
      api:
        timeoutMs: 3000
        retries: 2
    YAML
  }

  deployment_matrix = {
    for pair in setproduct(keys(local.environments), keys(local.configuration_profiles)) :
    "${pair[0]}:${pair[1]}" => {
      environment = pair[0]
      profile     = pair[1]
      strategy    = pair[0] == "prod" ? "canary_10_percent_5_minutes" : "linear_20_percent_1_minute"
    }
  }
}

resource "aws_appconfig_application" "this" {
  name        = local.app_name
  description = "Centralized configuration for ECS/Fargate services (replaces Spring Cloud Config server)"

  tags = local.common_tags
}

resource "aws_appconfig_environment" "this" {
  for_each = local.environments

  application_id = aws_appconfig_application.this.id
  name           = each.key
  description    = each.value.description

  tags = merge(local.common_tags, { Environment = each.key })
}

resource "aws_appconfig_configuration_profile" "this" {
  for_each = local.configuration_profiles

  application_id = aws_appconfig_application.this.id
  name           = each.value.name
  description    = each.value.description
  location_uri   = "hosted"
  type           = "AWS.Freeform"

  tags = merge(local.common_tags, { Profile = each.value.name })
}

resource "aws_appconfig_hosted_configuration_version" "this" {
  for_each = local.configuration_profiles

  application_id           = aws_appconfig_application.this.id
  configuration_profile_id = aws_appconfig_configuration_profile.this[each.key].configuration_profile_id
  description              = "Initial hosted configuration for ${each.value.name}"
  content_type             = each.value.content_type
  content                  = local.profile_contents[each.key]
}

resource "aws_appconfig_deployment_strategy" "linear_20_percent_1_minute" {
  name                           = "linear-20-percent-every-1-minute"
  description                    = "Linear rollout of 20% every 1 minute"
  deployment_duration_in_minutes = 5
  growth_factor                  = 20
  growth_type                    = "LINEAR"
  final_bake_time_in_minutes     = 1
  replicate_to                   = "NONE"

  tags = merge(local.common_tags, { Strategy = "linear" })
}

resource "aws_appconfig_deployment_strategy" "canary_10_percent_5_minutes" {
  name                           = "canary-10-percent-then-90"
  description                    = "Canary rollout: 10% then remaining after bake"
  deployment_duration_in_minutes = 10
  growth_factor                  = 10
  growth_type                    = "LINEAR"
  final_bake_time_in_minutes     = 5
  replicate_to                   = "NONE"

  tags = merge(local.common_tags, { Strategy = "canary" })
}

resource "aws_appconfig_deployment" "this" {
  for_each = local.deployment_matrix

  application_id           = aws_appconfig_application.this.id
  environment_id           = aws_appconfig_environment.this[each.value.environment].environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.this[each.value.profile].configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.this[each.value.profile].version_number
  deployment_strategy_id   = each.value.strategy == "canary_10_percent_5_minutes" ? aws_appconfig_deployment_strategy.canary_10_percent_5_minutes.id : aws_appconfig_deployment_strategy.linear_20_percent_1_minute.id
  description              = "Initial deployment of ${each.value.profile} profile to ${each.value.environment}"

  depends_on = [
    aws_appconfig_hosted_configuration_version.this,
    aws_appconfig_deployment_strategy.linear_20_percent_1_minute,
    aws_appconfig_deployment_strategy.canary_10_percent_5_minutes
  ]
}

output "appconfig_application_id" {
  description = "AppConfig Application ID"
  value       = aws_appconfig_application.this.id
}

output "appconfig_environment_ids" {
  description = "Environment IDs by environment name"
  value = {
    for k, v in aws_appconfig_environment.this : k => v.environment_id
  }
}

output "appconfig_configuration_profile_ids" {
  description = "Configuration Profile IDs by profile key"
  value = {
    for k, v in aws_appconfig_configuration_profile.this : k => v.configuration_profile_id
  }
}