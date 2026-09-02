#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: Required environment variable '$var_name' is not set."
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' is not installed or not in PATH."
    exit 1
  fi
}

require_cmd aws
require_cmd jq

require_env AWS_REGION
require_env AWS_ACCOUNT_ID
require_env ECR_REPOSITORY
require_env ECS_CLUSTER

if [[ -z "${ECS_SERVICES:-}" && -z "${ECS_SERVICE:-}" ]]; then
  echo "ERROR: Set ECS_SERVICES (comma-separated) or ECS_SERVICE (single service)."
  exit 1
fi

IMAGE_TAG="${IMAGE_TAG:-${TRAVIS_COMMIT:-latest}}"
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
IMAGE_URI="${IMAGE_URI:-${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}}"

if [[ -n "${ECS_SERVICES:-}" ]]; then
  IFS=',' read -r -a SERVICE_LIST <<< "$ECS_SERVICES"
else
  SERVICE_LIST=("$ECS_SERVICE")
fi

echo "Starting ECS deployment"
echo "Cluster: $ECS_CLUSTER"
echo "Services: ${SERVICE_LIST[*]}"
echo "Image: $IMAGE_URI"

deploy_service() {
  local service_name="$1"
  echo "---"
  echo "Deploying service: $service_name"

  local current_task_def_arn
  current_task_def_arn="$(aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$service_name" \
    --query 'services[0].taskDefinition' \
    --output text)"

  if [[ -z "$current_task_def_arn" || "$current_task_def_arn" == "None" ]]; then
    echo "ERROR: Could not resolve current task definition ARN for service '$service_name'."
    exit 1
  fi

  local task_def_json
  task_def_json="$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$current_task_def_arn" \
    --query 'taskDefinition' \
    --output json)"

  local container_name
  if [[ -n "${CONTAINER_NAME:-}" ]]; then
    container_name="$CONTAINER_NAME"
  else
    container_name="$(echo "$task_def_json" | jq -r '.containerDefinitions[0].name')"
  fi

  if [[ -z "$container_name" || "$container_name" == "null" ]]; then
    echo "ERROR: Could not determine container name for service '$service_name'."
    exit 1
  fi

  local target_count
  target_count="$(echo "$task_def_json" | jq --arg cn "$container_name" '[.containerDefinitions[] | select(.name == $cn)] | length')"

  if [[ "$target_count" -eq 0 ]]; then
    echo "ERROR: Container '$container_name' not found in task definition for service '$service_name'."
    exit 1
  fi

  local new_task_def_payload
  new_task_def_payload="$(echo "$task_def_json" | jq -c \
    --arg IMAGE_URI "$IMAGE_URI" \
    --arg CONTAINER_NAME "$container_name" '
      {
        family,
        taskRoleArn,
        executionRoleArn,
        networkMode,
        containerDefinitions: (.containerDefinitions | map(if .name == $CONTAINER_NAME then .image = $IMAGE_URI else . end)),
        volumes,
        placementConstraints,
        requiresCompatibilities,
        cpu,
        memory,
        pidMode,
        ipcMode,
        proxyConfiguration,
        inferenceAccelerators,
        ephemeralStorage,
        runtimePlatform,
        tags
      }
      | with_entries(select(.value != null))
    ')"

  local register_output
  register_output="$(aws ecs register-task-definition \
    --region "$AWS_REGION" \
    --cli-input-json "$new_task_def_payload")"

  local new_task_def_arn
  new_task_def_arn="$(echo "$register_output" | jq -r '.taskDefinition.taskDefinitionArn')"

  if [[ -z "$new_task_def_arn" || "$new_task_def_arn" == "null" ]]; then
    echo "ERROR: Failed to register new task definition for service '$service_name'."
    exit 1
  fi

  echo "Registered task definition: $new_task_def_arn"

  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --service "$service_name" \
    --task-definition "$new_task_def_arn" \
    --force-new-deployment \
    >/dev/null

  echo "Waiting for service '$service_name' to become stable..."
  aws ecs wait services-stable \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$service_name"

  echo "Service '$service_name' deployment completed."
}

for svc in "${SERVICE_LIST[@]}"; do
  svc="$(echo "$svc" | xargs)"
  [[ -z "$svc" ]] && continue
  deploy_service "$svc"
done

echo "ECS deployment finished successfully.
"