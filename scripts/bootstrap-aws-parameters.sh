#!/usr/bin/env bash
set -euo pipefail

# bootstrap-aws-parameters.sh
#
# Populates/updates:
# 1) AWS Secrets Manager secrets (sensitive values)
# 2) AWS Systems Manager Parameter Store parameters (non-secret configuration + secret references)
#
# Usage:
#   ./scripts/bootstrap-aws-parameters.sh <environment>
#
# Example:
#   APP_NAME=myapp AWS_REGION=us-east-1 ./scripts/bootstrap-aws-parameters.sh dev
#
# Required secret env vars:
#   DOCDB_USERNAME, DOCDB_PASSWORD
#   RABBITMQ_USERNAME, RABBITMQ_PASSWORD
#   SES_SMTP_USERNAME, SES_SMTP_PASSWORD
#   API_JWT_SIGNING_KEY
#
# Optional non-secret env vars (defaults applied when omitted):
#   DOCDB_CLUSTER_ENDPOINT, DOCDB_PORT(27017), DOCDB_DB_NAME(app)
#   CLOUD_MAP_NAMESPACE_ID, CLOUD_MAP_NAMESPACE_NAME, CLOUD_MAP_SERVICE_NAME
#   SES_FROM_EMAIL, SES_CONFIGURATION_SET
#   MQ_BROKER_ID, MQ_ENDPOINT, MQ_VHOST(/)
#   API_GATEWAY_ID, API_GATEWAY_STAGE(<environment>), API_GATEWAY_BASE_URL
#   KMS_KEY_ID (used when creating new secrets)

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: Required environment variable is missing: ${var_name}" >&2
    exit 1
  fi
}

resolve_region() {
  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "${AWS_REGION}"
    return
  fi

  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "${AWS_DEFAULT_REGION}"
    return
  fi

  local configured_region
  configured_region="$(aws configure get region 2>/dev/null || true)"
  if [[ -n "${configured_region}" ]]; then
    echo "${configured_region}"
    return
  fi

  echo "ERROR: AWS region not set. Export AWS_REGION or AWS_DEFAULT_REGION." >&2
  exit 1
}

upsert_secret_json() {
  local secret_id="$1"
  local secret_payload="$2"
  local description="$3"

  if aws "${AWS_ARGS[@]}" secretsmanager describe-secret --secret-id "${secret_id}" >/dev/null 2>&1; then
    aws "${AWS_ARGS[@]}" secretsmanager update-secret \
      --secret-id "${secret_id}" \
      --secret-string "${secret_payload}" >/dev/null
  else
    if [[ -n "${KMS_KEY_ID:-}" ]]; then
      aws "${AWS_ARGS[@]}" secretsmanager create-secret \
        --name "${secret_id}" \
        --description "${description}" \
        --kms-key-id "${KMS_KEY_ID}" \
        --secret-string "${secret_payload}" >/dev/null
    else
      aws "${AWS_ARGS[@]}" secretsmanager create-secret \
        --name "${secret_id}" \
        --description "${description}" \
        --secret-string "${secret_payload}" >/dev/null
    fi
  fi

  aws "${AWS_ARGS[@]}" secretsmanager describe-secret --secret-id "${secret_id}" --query 'ARN' --output text
}

put_param() {
  local name="$1"
  local value="$2"
  local description="$3"

  aws "${AWS_ARGS[@]}" ssm put-parameter \
    --name "${name}" \
    --type "String" \
    --value "${value}" \
    --description "${description}" \
    --overwrite >/dev/null
}

main() {
  require_cmd aws
  require_cmd jq

  local environment="${1:-${ENVIRONMENT:-}}"
  if [[ -z "${environment}" ]]; then
    echo "Usage: $0 <environment>" >&2
    exit 1
  fi

  local app_name="${APP_NAME:-application}"
  local region
  region="$(resolve_region)"
  AWS_ARGS=(--region "${region}")

  # Required secret material
  require_env DOCDB_USERNAME
  require_env DOCDB_PASSWORD
  require_env RABBITMQ_USERNAME
  require_env RABBITMQ_PASSWORD
  require_env SES_SMTP_USERNAME
  require_env SES_SMTP_PASSWORD
  require_env API_JWT_SIGNING_KEY

  # Optional non-secret config
  local docdb_cluster_endpoint="${DOCDB_CLUSTER_ENDPOINT:-}"
  local docdb_port="${DOCDB_PORT:-27017}"
  local docdb_db_name="${DOCDB_DB_NAME:-app}"

  local cloud_map_namespace_id="${CLOUD_MAP_NAMESPACE_ID:-}"
  local cloud_map_namespace_name="${CLOUD_MAP_NAMESPACE_NAME:-}"
  local cloud_map_service_name="${CLOUD_MAP_SERVICE_NAME:-}"

  local ses_from_email="${SES_FROM_EMAIL:-}"
  local ses_configuration_set="${SES_CONFIGURATION_SET:-}"

  local mq_broker_id="${MQ_BROKER_ID:-}"
  local mq_endpoint="${MQ_ENDPOINT:-}"
  local mq_vhost="${MQ_VHOST:-/}"

  local api_gateway_id="${API_GATEWAY_ID:-}"
  local api_gateway_stage="${API_GATEWAY_STAGE:-${environment}}"
  local api_gateway_base_url="${API_GATEWAY_BASE_URL:-}"

  # Naming conventions
  local secret_base="${app_name}/${environment}"
  local param_config_base="/${app_name}/${environment}/config"
  local param_ref_base="/${app_name}/${environment}/refs"

  local docdb_secret_id="${secret_base}/documentdb"
  local rabbitmq_secret_id="${secret_base}/rabbitmq"
  local ses_secret_id="${secret_base}/ses"
  local api_secret_id="${secret_base}/api"

  echo "Bootstrapping AWS configuration for app=${app_name}, env=${environment}, region=${region}"

  # Build secret payloads
  local docdb_secret_json
  docdb_secret_json="$(jq -cn --arg username "${DOCDB_USERNAME}" --arg password "${DOCDB_PASSWORD}" '{username:$username,password:$password}')"

  local rabbitmq_secret_json
  rabbitmq_secret_json="$(jq -cn --arg username "${RABBITMQ_USERNAME}" --arg password "${RABBITMQ_PASSWORD}" '{username:$username,password:$password}')"

  local ses_secret_json
  ses_secret_json="$(jq -cn --arg smtp_username "${SES_SMTP_USERNAME}" --arg smtp_password "${SES_SMTP_PASSWORD}" '{smtp_username:$smtp_username,smtp_password:$smtp_password}')"

  local api_secret_json
  api_secret_json="$(jq -cn --arg jwt_signing_key "${API_JWT_SIGNING_KEY}" '{jwt_signing_key:$jwt_signing_key}')"

  # Upsert secrets and capture ARNs
  local docdb_secret_arn
  local rabbitmq_secret_arn
  local ses_secret_arn
  local api_secret_arn

  docdb_secret_arn="$(upsert_secret_json "${docdb_secret_id}" "${docdb_secret_json}" "${app_name} ${environment} DocumentDB credentials")"
  rabbitmq_secret_arn="$(upsert_secret_json "${rabbitmq_secret_id}" "${rabbitmq_secret_json}" "${app_name} ${environment} RabbitMQ credentials")"
  ses_secret_arn="$(upsert_secret_json "${ses_secret_id}" "${ses_secret_json}" "${app_name} ${environment} SES SMTP credentials")"
  api_secret_arn="$(upsert_secret_json "${api_secret_id}" "${api_secret_json}" "${app_name} ${environment} API signing secrets")"

  # Store non-secret config parameters (service endpoints, IDs, metadata)
  put_param "${param_config_base}/aws_region" "${region}" "AWS region"

  put_param "${param_config_base}/documentdb/cluster_endpoint" "${docdb_cluster_endpoint}" "Amazon DocumentDB cluster endpoint"
  put_param "${param_config_base}/documentdb/port" "${docdb_port}" "Amazon DocumentDB port"
  put_param "${param_config_base}/documentdb/database_name" "${docdb_db_name}" "Amazon DocumentDB database name"

  put_param "${param_config_base}/cloud_map/namespace_id" "${cloud_map_namespace_id}" "AWS Cloud Map namespace ID"
  put_param "${param_config_base}/cloud_map/namespace_name" "${cloud_map_namespace_name}" "AWS Cloud Map namespace name"
  put_param "${param_config_base}/cloud_map/service_name" "${cloud_map_service_name}" "AWS Cloud Map service name"

  put_param "${param_config_base}/ses/from_email" "${ses_from_email}" "Amazon SES from email"
  put_param "${param_config_base}/ses/configuration_set" "${ses_configuration_set}" "Amazon SES configuration set"

  put_param "${param_config_base}/mq/broker_id" "${mq_broker_id}" "Amazon MQ for RabbitMQ broker ID"
  put_param "${param_config_base}/mq/endpoint" "${mq_endpoint}" "Amazon MQ for RabbitMQ endpoint"
  put_param "${param_config_base}/mq/vhost" "${mq_vhost}" "Amazon MQ for RabbitMQ vhost"

  put_param "${param_config_base}/api_gateway/rest_api_id" "${api_gateway_id}" "Amazon API Gateway REST API ID"
  put_param "${param_config_base}/api_gateway/stage" "${api_gateway_stage}" "Amazon API Gateway stage"
  put_param "${param_config_base}/api_gateway/base_url" "${api_gateway_base_url}" "Amazon API Gateway base URL"

  # Store non-secret references to secrets (for runtime config resolution)
  put_param "${param_ref_base}/documentdb_secret_id" "${docdb_secret_id}" "Secrets Manager secret ID for DocumentDB"
  put_param "${param_ref_base}/documentdb_secret_arn" "${docdb_secret_arn}" "Secrets Manager secret ARN for DocumentDB"

  put_param "${param_ref_base}/rabbitmq_secret_id" "${rabbitmq_secret_id}" "Secrets Manager secret ID for RabbitMQ"
  put_param "${param_ref_base}/rabbitmq_secret_arn" "${rabbitmq_secret_arn}" "Secrets Manager secret ARN for RabbitMQ"

  put_param "${param_ref_base}/ses_secret_id" "${ses_secret_id}" "Secrets Manager secret ID for SES"
  put_param "${param_ref_base}/ses_secret_arn" "${ses_secret_arn}" "Secrets Manager secret ARN for SES"

  put_param "${param_ref_base}/api_secret_id" "${api_secret_id}" "Secrets Manager secret ID for API"
  put_param "${param_ref_base}/api_secret_arn" "${api_secret_arn}" "Secrets Manager secret ARN for API"

  echo "Bootstrap complete."
  echo "Updated secrets:"
  echo "  - ${docdb_secret_id}"
  echo "  - ${rabbitmq_secret_id}"
  echo "  - ${ses_secret_id}"
  echo "  - ${api_secret_id}"
  echo "Updated parameter paths:"
  echo "  - ${param_config_base}/..."
  echo "  - ${param_ref_base}/..."
}

main "$@"