terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

resource "aws_apigatewayv2_api" "http_api" {
  name          = "${local.name_prefix}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["authorization", "content-type", "x-requested-with", "x-api-key"]
    allow_methods     = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_origins     = var.cors_allow_origins
    expose_headers    = ["content-type", "x-amzn-requestid"]
    max_age           = 300
  }

  tags = local.default_tags
}

resource "aws_cloudwatch_log_group" "api_access_logs" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.http_api.name}"
  retention_in_days = var.log_retention_days
  tags              = local.default_tags
}

resource "aws_apigatewayv2_vpc_link" "private_link" {
  name               = "${local.name_prefix}-apigw-vpc-link"
  security_group_ids = var.vpc_link_security_group_ids
  subnet_ids         = var.private_subnet_ids
  tags               = local.default_tags
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  count = var.enable_jwt_authorizer ? 1 : 0

  api_id           = aws_apigatewayv2_api.http_api.id
  name             = "${local.name_prefix}-jwt-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = var.jwt_audiences
    issuer   = var.jwt_issuer
  }
}

resource "aws_apigatewayv2_integration" "backend" {
  api_id = aws_apigatewayv2_api.http_api.id

  integration_type        = "HTTP_PROXY"
  integration_method      = "ANY"
  integration_uri         = var.backend_integration_uri
  payload_format_version  = "1.0"
  timeout_milliseconds    = var.integration_timeout_ms
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.private_link.id
  tls_config {
    server_name_to_verify = var.tls_server_name_to_verify
  }
}

resource "aws_apigatewayv2_route" "routes" {
  for_each = { for r in var.routes : r.route_key => r }

  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = each.value.route_key
  target    = "integrations/${aws_apigatewayv2_integration.backend.id}"

  authorization_type = each.value.authorization_type
  authorizer_id = each.value.authorization_type == "JWT" && var.enable_jwt_authorizer ? aws_apigatewayv2_authorizer.jwt[0].id : null
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access_logs.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      sourceIp         = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.route_throttling_burst_limit
    throttling_rate_limit    = var.route_throttling_rate_limit
  }

  tags = local.default_tags
}

variable "project_name" {
  description = "Application/project name used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by API Gateway VPC Link."
  type        = list(string)
}

variable "vpc_link_security_group_ids" {
  description = "Security groups attached to API Gateway VPC Link ENIs."
  type        = list(string)
}

variable "backend_integration_uri" {
  description = "Private integration URI. Usually an NLB listener ARN or Cloud Map service ARN for ECS/Fargate private integrations."
  type        = string
}

variable "routes" {
  description = "API routes to expose. Example: [{ route_key = \"GET /health\", authorization_type = \"NONE\" }, { route_key = \"ANY /api/{proxy+}\", authorization_type = \"JWT\" }]"
  type = list(object({
    route_key          = string
    authorization_type = string
  }))

  validation {
    condition = alltrue([
      for r in var.routes : contains(["NONE", "JWT", "AWS_IAM"], r.authorization_type)
    ])
    error_message = "authorization_type must be one of: NONE, JWT, AWS_IAM."
  }
}

variable "enable_jwt_authorizer" {
  description = "Set true to create and attach a JWT authorizer for routes using authorization_type=JWT."
  type        = bool
  default     = false
}

variable "jwt_issuer" {
  description = "JWT issuer URL (required when enable_jwt_authorizer=true)."
  type        = string
  default     = null
}

variable "jwt_audiences" {
  description = "JWT audiences (required when enable_jwt_authorizer=true)."
  type        = list(string)
  default     = []
}

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the HTTP API."
  type        = list(string)
  default     = ["*"]
}

variable "integration_timeout_ms" {
  description = "Backend integration timeout in milliseconds."
  type        = number
  default     = 29000
}

variable "tls_server_name_to_verify" {
  description = "TLS server name used for certificate verification on private integration."
  type        = string
  default     = "internal.local"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for API Gateway access logs."
  type        = number
  default     = 14
}

variable "route_throttling_burst_limit" {
  description = "Stage default route throttling burst limit."
  type        = number
  default     = 200
}

variable "route_throttling_rate_limit" {
  description = "Stage default route throttling rate limit (requests/second)."
  type        = number
  default     = 100
}

output "api_gateway_id" {
  description = "HTTP API Gateway ID."
  value       = aws_apigatewayv2_api.http_api.id
}

output "api_gateway_endpoint" {
  description = "Invoke URL for the HTTP API default stage."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_gateway_execution_arn" {
  description = "Execution ARN for IAM permissions and integrations."
  value       = aws_apigatewayv2_api.http_api.execution_arn
}