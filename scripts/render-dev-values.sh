#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# render-dev-values.sh
#
# SSM Parameter Store에서 인프라 식별자를 읽어
# charts/safespot-observability/values-${ENVIRONMENT}.infra.generated.yaml 생성
#
# 사용법:
#   AWS_PROFILE=<profile> ./scripts/render-dev-values.sh
#   AWS_PROFILE=<profile> ENVIRONMENT=dev ./scripts/render-dev-values.sh
#
# 환경 변수:
#   AWS_PROFILE   (선택) AWS CLI 프로파일
#   AWS_REGION    (선택, 기본값: ap-northeast-2)
#   ENVIRONMENT   (선택, 기본값: dev)
#   PROJECT       (선택, 기본값: safespot)
#
# 필수 SSM parameters:
#   /${PROJECT}/${ENVIRONMENT}/data/redis-primary-endpoint
#   /${PROJECT}/${ENVIRONMENT}/data/redis-port
#   /${PROJECT}/${ENVIRONMENT}/observability/yace/irsa-role-arn
#   /${PROJECT}/${ENVIRONMENT}/async-worker/cache-refresh-queue-url
#   /${PROJECT}/${ENVIRONMENT}/async-worker/readmodel-refresh-queue-url
#   /${PROJECT}/${ENVIRONMENT}/async-worker/environment-cache-refresh-queue-url
#   /${PROJECT}/${ENVIRONMENT}/async-worker/event-queue-url
#
# 선택 SSM parameters:
#   /${PROJECT}/${ENVIRONMENT}/observability/grafana/irsa-role-arn
#   /${PROJECT}/${ENVIRONMENT}/observability/prometheus/irsa-role-arn
#   /${PROJECT}/${ENVIRONMENT}/observability/fluent-bit/irsa-role-arn
#   /${PROJECT}/${ENVIRONMENT}/data/aurora-cluster-identifier
#   /${PROJECT}/${ENVIRONMENT}/data/redis-replication-group-id
#   /${PROJECT}/${ENVIRONMENT}/async-worker/lambda-function-name
#   /${PROJECT}/${ENVIRONMENT}/front-edge/alb-arn-suffix
# DLQ SSM parameters (name preferred, URL fallback):
#   /${PROJECT}/${ENVIRONMENT}/async-worker/cache-refresh-dlq-name
#   /${PROJECT}/${ENVIRONMENT}/async-worker/cache-refresh-dlq-url
#   /${PROJECT}/${ENVIRONMENT}/async-worker/readmodel-refresh-dlq-name
#   /${PROJECT}/${ENVIRONMENT}/async-worker/readmodel-refresh-dlq-url
#   /${PROJECT}/${ENVIRONMENT}/async-worker/environment-cache-refresh-dlq-name
#   /${PROJECT}/${ENVIRONMENT}/async-worker/environment-cache-refresh-dlq-url
# ---------------------------------------------------------------------------

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT="${PROJECT:-safespot}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/safespot-observability"
OUTPUT_FILE="${CHART_DIR}/values-${ENVIRONMENT}.infra.generated.yaml"

# ---------------------------------------------------------------------------
# SSM helper functions
# ---------------------------------------------------------------------------

get_required_parameter() {
  local name="$1"
  local value

  value="$(aws ssm get-parameter \
    --name "$name" \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text)"

  if [[ -z "$value" || "$value" == "None" ]]; then
    echo "ERROR: required SSM parameter is empty or not found: $name" >&2
    exit 1
  fi

  printf '%s' "$value"
}

get_optional_parameter() {
  local name="$1"
  local value

  value="$(aws ssm get-parameter \
    --name "$name" \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || true)"

  if [[ "$value" == "None" ]]; then
    value=""
  fi

  printf '%s' "$value"
}

queue_name_from_url() {
  local url="$1"
  basename "$url"
}

# Resolve DLQ queue name with priority: *-dlq-name param > *-dlq-url basename > ""
resolve_dlq_name() {
  local prefix="$1"
  local name_param="/${PROJECT}/${ENVIRONMENT}/async-worker/${prefix}-dlq-name"
  local url_param="/${PROJECT}/${ENVIRONMENT}/async-worker/${prefix}-dlq-url"

  local name
  name="$(get_optional_parameter "${name_param}")"
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
    return
  fi

  local url
  url="$(get_optional_parameter "${url_param}")"
  if [[ -n "$url" ]]; then
    queue_name_from_url "$url"
    return
  fi

  printf '%s' ""
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ ! -d "$CHART_DIR" ]]; then
  echo "ERROR: chart directory not found: $CHART_DIR" >&2
  exit 1
fi

echo "=== render-dev-values.sh ==="
echo "  Project:     ${PROJECT}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Region:      ${AWS_REGION}"
echo "  Output:      ${OUTPUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Read SSM parameters
# ---------------------------------------------------------------------------

echo "[1/3] Reading required SSM parameters ..."

REDIS_PRIMARY_ENDPOINT="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/data/redis-primary-endpoint")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/data/redis-primary-endpoint"

REDIS_PORT="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/data/redis-port")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/data/redis-port"

YACE_IRSA_ROLE_ARN="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/observability/yace/irsa-role-arn")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/observability/yace/irsa-role-arn"

_CACHE_REFRESH_URL="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/async-worker/cache-refresh-queue-url")"
CACHE_REFRESH_QUEUE_NAME="$(queue_name_from_url "${_CACHE_REFRESH_URL}")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/async-worker/cache-refresh-queue-url → ${CACHE_REFRESH_QUEUE_NAME}"

_READMODEL_REFRESH_URL="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/async-worker/readmodel-refresh-queue-url")"
READMODEL_REFRESH_QUEUE_NAME="$(queue_name_from_url "${_READMODEL_REFRESH_URL}")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/async-worker/readmodel-refresh-queue-url → ${READMODEL_REFRESH_QUEUE_NAME}"

_ENV_CACHE_REFRESH_URL="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/async-worker/environment-cache-refresh-queue-url")"
ENVIRONMENT_CACHE_REFRESH_QUEUE_NAME="$(queue_name_from_url "${_ENV_CACHE_REFRESH_URL}")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/async-worker/environment-cache-refresh-queue-url → ${ENVIRONMENT_CACHE_REFRESH_QUEUE_NAME}"

_EVENT_URL="$(get_required_parameter "/${PROJECT}/${ENVIRONMENT}/async-worker/event-queue-url")"
EVENT_QUEUE_NAME="$(queue_name_from_url "${_EVENT_URL}")"
echo "  OK  /${PROJECT}/${ENVIRONMENT}/async-worker/event-queue-url → ${EVENT_QUEUE_NAME}"

echo "[2/3] Reading optional SSM parameters ..."

FLUENT_BIT_IRSA_ROLE_ARN="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/observability/fluentbit/irsa-role-arn")"
if [[ -z "$FLUENT_BIT_IRSA_ROLE_ARN" ]]; then
  echo "  WARN /${PROJECT}/${ENVIRONMENT}/observability/fluentbit/irsa-role-arn (not found — fluent-bit IRSA annotation will be TODO_GENERATED_VALUE)"
else
  echo "  OK   /${PROJECT}/${ENVIRONMENT}/observability/fluentbit/irsa-role-arn"
fi

GRAFANA_IRSA_ROLE_ARN="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/observability/grafana/irsa-role-arn")"
if [[ -z "$GRAFANA_IRSA_ROLE_ARN" ]]; then
  echo "  SKIP /${PROJECT}/${ENVIRONMENT}/observability/grafana/irsa-role-arn (not found — Grafana IRSA annotation will be omitted)"
else
  echo "  OK   /${PROJECT}/${ENVIRONMENT}/observability/grafana/irsa-role-arn"
fi

PROMETHEUS_IRSA_ROLE_ARN="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/observability/prometheus/irsa-role-arn")"
if [[ -z "$PROMETHEUS_IRSA_ROLE_ARN" ]]; then
  echo "  SKIP /${PROJECT}/${ENVIRONMENT}/observability/prometheus/irsa-role-arn (not found — Prometheus IRSA annotation will be omitted)"
else
  echo "  OK   /${PROJECT}/${ENVIRONMENT}/observability/prometheus/irsa-role-arn"
fi

FLUENTBIT_IRSA_ROLE_ARN="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/observability/fluent-bit/irsa-role-arn")"
if [[ -z "$FLUENTBIT_IRSA_ROLE_ARN" ]]; then
  echo "  SKIP /${PROJECT}/${ENVIRONMENT}/observability/fluent-bit/irsa-role-arn (not found — Fluent Bit IRSA annotation will be omitted)"
else
  echo "  OK   /${PROJECT}/${ENVIRONMENT}/observability/fluent-bit/irsa-role-arn"
fi

RDS_CLUSTER_IDENTIFIER="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/data/aurora-cluster-identifier")"
[[ -z "$RDS_CLUSTER_IDENTIFIER" ]] \
  && echo "  SKIP /${PROJECT}/${ENVIRONMENT}/data/aurora-cluster-identifier" \
  || echo "  OK   /${PROJECT}/${ENVIRONMENT}/data/aurora-cluster-identifier"

REDIS_REPLICATION_GROUP_ID="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/data/redis-replication-group-id")"
[[ -z "$REDIS_REPLICATION_GROUP_ID" ]] \
  && echo "  SKIP /${PROJECT}/${ENVIRONMENT}/data/redis-replication-group-id" \
  || echo "  OK   /${PROJECT}/${ENVIRONMENT}/data/redis-replication-group-id"

LAMBDA_FUNCTION_NAME="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/async-worker/lambda-function-name")"
[[ -z "$LAMBDA_FUNCTION_NAME" ]] \
  && echo "  SKIP /${PROJECT}/${ENVIRONMENT}/async-worker/lambda-function-name" \
  || echo "  OK   /${PROJECT}/${ENVIRONMENT}/async-worker/lambda-function-name"

ALB_ARN_SUFFIX="$(get_optional_parameter "/${PROJECT}/${ENVIRONMENT}/front-edge/alb-arn-suffix")"
[[ -z "$ALB_ARN_SUFFIX" ]] \
  && echo "  SKIP /${PROJECT}/${ENVIRONMENT}/front-edge/alb-arn-suffix" \
  || echo "  OK   /${PROJECT}/${ENVIRONMENT}/front-edge/alb-arn-suffix"

CACHE_REFRESH_DLQ_NAME="$(resolve_dlq_name "cache-refresh")"
[[ -z "$CACHE_REFRESH_DLQ_NAME" ]] \
  && echo "  SKIP DLQ cache-refresh (no *-dlq-name or *-dlq-url in SSM)" \
  || echo "  OK   DLQ cache-refresh → ${CACHE_REFRESH_DLQ_NAME}"

READMODEL_REFRESH_DLQ_NAME="$(resolve_dlq_name "readmodel-refresh")"
[[ -z "$READMODEL_REFRESH_DLQ_NAME" ]] \
  && echo "  SKIP DLQ readmodel-refresh (no *-dlq-name or *-dlq-url in SSM)" \
  || echo "  OK   DLQ readmodel-refresh → ${READMODEL_REFRESH_DLQ_NAME}"

ENVIRONMENT_CACHE_REFRESH_DLQ_NAME="$(resolve_dlq_name "environment-cache-refresh")"
[[ -z "$ENVIRONMENT_CACHE_REFRESH_DLQ_NAME" ]] \
  && echo "  SKIP DLQ environment-cache-refresh (no *-dlq-name or *-dlq-url in SSM)" \
  || echo "  OK   DLQ environment-cache-refresh → ${ENVIRONMENT_CACHE_REFRESH_DLQ_NAME}"

# ---------------------------------------------------------------------------
# Generate values file
# ---------------------------------------------------------------------------

echo "[3/3] Generating ${OUTPUT_FILE} ..."

{
  cat <<HEADER
# ---------------------------------------------------------------------------
# Auto-generated by scripts/render-dev-values.sh — do NOT edit manually.
# Generated:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Environment: ${ENVIRONMENT}
# Project:     ${PROJECT}
# Region:      ${AWS_REGION}
#
# Apply after values-dev-eks.yaml:
#   helm template safespot-observability charts/safespot-observability \\
#     -n monitoring \\
#     -f charts/safespot-observability/values-dev-eks.yaml \\
#     -f ${OUTPUT_FILE} \\
#     --api-versions monitoring.coreos.com/v1
# ---------------------------------------------------------------------------

HEADER

  # Redis exporter endpoint + port (required)
  cat <<REDIS
redis-exporter:
  redisAddress: "redis://${REDIS_PRIMARY_ENDPOINT}:${REDIS_PORT}"

REDIS

  # Fluent Bit IRSA annotation (optional)
  if [[ -n "${FLUENTBIT_IRSA_ROLE_ARN}" ]]; then
    cat <<FLUENTBIT
fluent-bit:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${FLUENTBIT_IRSA_ROLE_ARN}"

FLUENTBIT
  else
    cat <<'FLUENTBIT_SKIP'
# fluent-bit.serviceAccount.annotations are not set.
# Fluent Bit IRSA role ARN was not found in SSM.

FLUENTBIT_SKIP
  fi

  # YACE IRSA annotation + generated config (required)
  cat <<YACE
yace:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${YACE_IRSA_ROLE_ARN}"
  config: |-
    apiVersion: v1alpha1
    sts-region: ${AWS_REGION}
    discovery:
      exportedTagsOnMetrics:
        AWS/RDS:
          - Name
        AWS/ElastiCache:
          - Name
      jobs:
        - type: AWS/RDS
          regions:
            - ${AWS_REGION}
          searchTags:
            - key: Name
              value: safespot-dev-data-aurora-cluster
          metrics:
            - name: CPUUtilization
              statistics:
                - Average
              period: 60
              length: 300
            - name: DatabaseConnections
              statistics:
                - Average
              period: 60
              length: 300
            - name: ReadLatency
              statistics:
                - Average
                - Maximum
              period: 60
              length: 300
            - name: WriteLatency
              statistics:
                - Average
                - Maximum
              period: 60
              length: 300
            - name: AuroraReplicaLag
              statistics:
                - Average
                - Maximum
              period: 60
              length: 300
            - name: VolumeBytesUsed
              statistics:
                - Average
              period: 60
              length: 300

        - type: AWS/ElastiCache
          regions:
            - ${AWS_REGION}
          searchTags:
            - key: Name
              value: safespot-dev-data-redis-main
          metrics:
            - name: EngineCPUUtilization
              statistics:
                - Average
              period: 60
              length: 300
            - name: Evictions
              statistics:
                - Sum
              period: 60
              length: 300
            - name: CurrConnections
              statistics:
                - Average
              period: 60
              length: 300
            - name: FreeableMemory
              statistics:
                - Average
              period: 60
              length: 300
            - name: BytesUsedForCache
              statistics:
                - Average
              period: 60
              length: 300

        - type: ContainerInsights
          regions:
            - ${AWS_REGION}
          searchTags:
            - key: Name
              value: safespot-dev-eks
          dimensionNameRequirements:
            - ClusterName
            - NodeName
          metrics:
            - name: node_cpu_utilization
              statistics:
                - Average
              period: 60
              length: 300
            - name: node_memory_utilization
              statistics:
                - Average
              period: 60
              length: 300
    static:

YACE

  if [[ -n "${CACHE_REFRESH_QUEUE_NAME}" ]]; then
    cat <<SQS_CACHE
      - namespace: AWS/SQS
        name: sqs-cache-refresh
        regions:
          - ${AWS_REGION}
        dimensions:
          - name: QueueName
            value: "${CACHE_REFRESH_QUEUE_NAME}"
        metrics:
          - name: ApproximateNumberOfMessagesVisible
            statistics: [Maximum]
            period: 60
            length: 300
          - name: ApproximateNumberOfMessagesNotVisible
            statistics: [Maximum]
            period: 60
            length: 300
          - name: ApproximateAgeOfOldestMessage
            statistics: [Maximum]
            period: 60
            length: 300
          - name: NumberOfMessagesSent
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesReceived
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesDeleted
            statistics: [Sum]
            period: 60
            length: 300
SQS_CACHE
  fi

  if [[ -n "${READMODEL_REFRESH_QUEUE_NAME}" ]]; then
    cat <<SQS_READMODEL
      - namespace: AWS/SQS
        name: sqs-readmodel-refresh
        regions:
          - ${AWS_REGION}
        dimensions:
          - name: QueueName
            value: "${READMODEL_REFRESH_QUEUE_NAME}"
        metrics:
          - name: ApproximateNumberOfMessagesVisible
            statistics: [Maximum]
            period: 60
            length: 300
          - name: ApproximateNumberOfMessagesNotVisible
            statistics: [Maximum]
            period: 60
            length: 300
          - name: ApproximateAgeOfOldestMessage
            statistics: [Maximum]
            period: 60
            length: 300
          - name: NumberOfMessagesSent
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesReceived
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesDeleted
            statistics: [Sum]
            period: 60
            length: 300
SQS_READMODEL
  fi

  if [[ -n "${ENVIRONMENT_CACHE_REFRESH_QUEUE_NAME}" ]]; then
    cat <<SQS_ENV
      - namespace: AWS/SQS
        name: sqs-env-cache-refresh
        regions:
          - ${AWS_REGION}
        dimensions:
          - name: QueueName
            value: "${ENVIRONMENT_CACHE_REFRESH_QUEUE_NAME}"
        metrics:
          - name: ApproximateNumberOfMessagesVisible
            statistics: [Maximum]
            period: 60
            length: 300
          - name: ApproximateAgeOfOldestMessage
            statistics: [Maximum]
            period: 60
            length: 300
          - name: NumberOfMessagesSent
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesReceived
            statistics: [Sum]
            period: 60
            length: 300
          - name: NumberOfMessagesDeleted
            statistics: [Sum]
            period: 60
            length: 300
SQS_ENV
  fi

  if [[ -n "${LAMBDA_FUNCTION_NAME}" ]]; then
    cat <<LAMBDA
      - namespace: AWS/Lambda
        name: lambda-async-worker
        regions:
          - ${AWS_REGION}
        dimensions:
          - name: FunctionName
            value: "${LAMBDA_FUNCTION_NAME}"
        metrics:
          - name: Invocations
            statistics: [Sum]
            period: 60
            length: 300
          - name: Errors
            statistics: [Sum]
            period: 60
            length: 300
          - name: Throttles
            statistics: [Sum]
            period: 60
            length: 300
          - name: Duration
            statistics: [Average, Maximum]
            period: 60
            length: 300
          - name: ConcurrentExecutions
            statistics: [Maximum]
            period: 60
            length: 300
LAMBDA
  fi

  echo ""

  # fluent-bit IRSA annotation (optional — warn if missing)
  if [[ -n "${FLUENT_BIT_IRSA_ROLE_ARN}" ]]; then
    cat <<FLUENTBIT
fluent-bit:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${FLUENT_BIT_IRSA_ROLE_ARN}"

FLUENTBIT
  fi

  # Grafana IRSA annotation (optional)
  # kube-prometheus-stack IRSA annotations (optional)
  if [[ -n "${GRAFANA_IRSA_ROLE_ARN}" || -n "${PROMETHEUS_IRSA_ROLE_ARN}" ]]; then
    cat <<KPS
kube-prometheus-stack:
KPS

    if [[ -n "${GRAFANA_IRSA_ROLE_ARN}" ]]; then
      cat <<GRAFANA
  grafana:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "${GRAFANA_IRSA_ROLE_ARN}"

GRAFANA
    fi

    if [[ -n "${PROMETHEUS_IRSA_ROLE_ARN}" ]]; then
      cat <<PROMETHEUS
  prometheus:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "${PROMETHEUS_IRSA_ROLE_ARN}"

PROMETHEUS
    fi
  else
    cat <<'KPS_SKIP'
# kube-prometheus-stack.serviceAccount.annotations are not set.
# Grafana/Prometheus IRSA role ARNs were not found in SSM.

KPS_SKIP
  fi

  # AWS resource identifiers
  # optional params absent in SSM → empty string → CloudWatch panels show "No data"
  cat <<AWS
safespot:
  aws:
    rds:
      dbClusterIdentifier: "${RDS_CLUSTER_IDENTIFIER}"
    elasticache:
      replicationGroupId: "${REDIS_REPLICATION_GROUP_ID}"
    sqs:
      eventQueueName: "${EVENT_QUEUE_NAME}"
      cacheRefreshQueueName: "${CACHE_REFRESH_QUEUE_NAME}"
      readmodelRefreshQueueName: "${READMODEL_REFRESH_QUEUE_NAME}"
      environmentCacheRefreshQueueName: "${ENVIRONMENT_CACHE_REFRESH_QUEUE_NAME}"
      cacheRefreshDlqName: "${CACHE_REFRESH_DLQ_NAME}"
      readmodelRefreshDlqName: "${READMODEL_REFRESH_DLQ_NAME}"
      environmentCacheRefreshDlqName: "${ENVIRONMENT_CACHE_REFRESH_DLQ_NAME}"
    lambda:
      asyncWorkerFunctionName: "${LAMBDA_FUNCTION_NAME}"
    alb:
      loadBalancerDimension: "${ALB_ARN_SUFFIX}"
AWS

} > "${OUTPUT_FILE}"

echo ""
echo "Generated: ${OUTPUT_FILE}"
echo ""
echo "Next steps:"
echo "  helm dependency build charts/safespot-observability"
echo "  helm template safespot-observability charts/safespot-observability \\"
echo "    -n monitoring \\"
echo "    -f charts/safespot-observability/values-dev-eks.yaml \\"
echo "    -f ${OUTPUT_FILE} \\"
echo "    --api-versions monitoring.coreos.com/v1"