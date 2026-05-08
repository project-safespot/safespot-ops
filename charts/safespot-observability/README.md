# safespot-observability

SafeSpot 전용 관측성 Helm Chart.

## Values 파일 구조

| 파일 | 용도 |
|------|------|
| `values.yaml` | 공통 기본값. 비밀/endpoint 없음. |
| `values-local.yaml` | 로컬 테스트용 (LoadBalancer, adminPassword). **커밋 주의.** |
| `values-dev-eks.yaml` | EKS dev 전용 구조 설정. 인프라 식별자 없음. |
| `values-dev.infra.template.yaml` | SSM 치환용 envsubst 템플릿 (참조용). |
| `values-dev.infra.generated.yaml` | **스크립트가 생성하는 파일. 직접 편집 금지.** |

## EKS dev 배포 절차

### 1. 인프라 values 생성

SSM Parameter Store에서 인프라 식별자를 읽어 generated values를 생성합니다.

```bash
AWS_PROFILE=<profile> ./scripts/render-dev-values.sh
```

필수 SSM parameters:
- `/safespot/dev/data/redis-primary-endpoint` — ElastiCache primary endpoint hostname
- `/safespot/dev/data/redis-port` — ElastiCache port
- `/safespot/dev/observability/yace/irsa-role-arn` — YACE IRSA role ARN
- `/safespot/dev/async-worker/cache-refresh-queue-url` — SQS queue URL (basename이 QueueName으로 사용됨)
- `/safespot/dev/async-worker/readmodel-refresh-queue-url`
- `/safespot/dev/async-worker/environment-cache-refresh-queue-url`
- `/safespot/dev/async-worker/event-queue-url` — Terraform `event_queue_*` output은 하위 호환을 위해 `cache_refresh` queue를 대표 event queue로 매핑합니다. `eventQueueName`과 `cacheRefreshQueueName`이 동일한 값으로 생성되는 것은 정상입니다.

선택 SSM parameters:
- `/safespot/dev/observability/grafana/irsa-role-arn` — Grafana CloudWatch datasource용 IRSA
- `/safespot/dev/data/aurora-cluster-identifier` — CloudWatch RDS 패널 dimension
- `/safespot/dev/data/redis-replication-group-id` — CloudWatch ElastiCache 패널 dimension
- `/safespot/dev/async-worker/lambda-function-name` — CloudWatch Lambda 패널 dimension
- `/safespot/dev/front-edge/alb-arn-suffix` — CloudWatch ALB 패널 dimension
- DLQ name (preferred) or URL (fallback) — CloudWatch DLQ 패널 dimension (자세한 내용은 아래 참조)

### 2. Dependency 빌드

```bash
helm dependency build charts/safespot-observability
```

### 3. Lint

```bash
helm lint charts/safespot-observability \
  -f charts/safespot-observability/values-dev-eks.yaml \
  -f charts/safespot-observability/values-dev.infra.generated.yaml
```

### 4. 렌더링 확인

```bash
helm template safespot-observability charts/safespot-observability \
  -n monitoring \
  -f charts/safespot-observability/values-dev-eks.yaml \
  -f charts/safespot-observability/values-dev.infra.generated.yaml \
  --api-versions monitoring.coreos.com/v1
```

렌더링 결과 확인:

```bash
helm template safespot-observability charts/safespot-observability \
  -n monitoring \
  -f charts/safespot-observability/values-dev-eks.yaml \
  -f charts/safespot-observability/values-dev.infra.generated.yaml \
  --api-versions monitoring.coreos.com/v1 \
  | grep -E "safespot-yace|safespot-grafana|eks.amazonaws.com/role-arn|redis://|kind: ServiceMonitor|kind: ExternalSecret"
```

### 5. 배포

```bash
helm upgrade --install safespot-observability charts/safespot-observability \
  -n monitoring --create-namespace \
  -f charts/safespot-observability/values-dev-eks.yaml \
  -f charts/safespot-observability/values-dev.infra.generated.yaml
```

## ArgoCD 연동

ArgoCD Application에서 values file 순서를 다음과 같이 맞추세요.

```yaml
spec:
  source:
    helm:
      valueFiles:
        - values-dev-eks.yaml
        - values-dev.infra.generated.yaml
```

`values-dev.infra.generated.yaml`은 ArgoCD가 읽는 Git 레포에 커밋되어 있어야 합니다.
CI/CD 파이프라인에서 `render-dev-values.sh`를 실행하고 결과를 커밋하는 구조로 사용하세요.

## EKS 배포 후 확인 항목

```bash
# Prometheus target 상태
kubectl -n monitoring port-forward svc/safespot-observability-kube-prometheus 9090

# Grafana에서 확인
# redis_up == 1
# redis_keyspace_hits_total 조회 가능
# aws_rds_cpuutilization_average 조회 가능
# aws_elasticache_engine_cpuutilization_average 조회 가능

# ExternalSecret 동기화 상태
kubectl -n monitoring get externalsecret grafana-admin-credentials

# YACE target
kubectl -n monitoring logs -l app.kubernetes.io/name=yace
```

## Grafana admin credential

Grafana admin 비밀번호는 `ExternalSecret`을 통해 SSM에서 자동 동기화됩니다.

필요 SSM parameters:
- `/safespot/dev/observability/grafana/admin-user`
- `/safespot/dev/observability/grafana/admin-password`

external-secrets operator가 없는 환경에서는:

```bash
kubectl -n monitoring create secret generic grafana-admin-credentials \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<password>
```

## 로컬 테스트

```bash
helm template safespot-observability charts/safespot-observability \
  -f charts/safespot-observability/values-local.yaml
```

## 후속 작업 (이번 PR 범위 외)

### DLQ 패널

CloudWatch dashboard에 3개 DLQ에 대한 패널(Visible Messages, Oldest Message Age)이 활성화되어 있습니다.

패널 렌더링 조건: `safespot.dashboards.cloudwatchRaw.enabled == true` and at least one DLQ QueueName is non-empty. QueueName이 비어 있는 DLQ target은 렌더링되지 않습니다.

지원 DLQ:
- `cache-refresh-dlq`
- `readmodel-refresh-dlq`
- `environment-cache-refresh-dlq`

`event-dlq`는 Terraform에서 backward-compatible representative DLQ로 `cache-refresh` DLQ를 가리키므로 별도 패널 target으로 추가하지 않습니다.

DLQ SSM parameters (name preferred, URL fallback):

| DLQ | name (preferred) | url (fallback) |
|-----|-----------------|----------------|
| cache-refresh | `/safespot/dev/async-worker/cache-refresh-dlq-name` | `/safespot/dev/async-worker/cache-refresh-dlq-url` |
| readmodel-refresh | `/safespot/dev/async-worker/readmodel-refresh-dlq-name` | `/safespot/dev/async-worker/readmodel-refresh-dlq-url` |
| environment-cache-refresh | `/safespot/dev/async-worker/environment-cache-refresh-dlq-name` | `/safespot/dev/async-worker/environment-cache-refresh-dlq-url` |

name parameter가 없으면 URL의 마지막 경로 segment를 QueueName으로 사용합니다 (`basename`). FIFO queue의 경우 `.fifo` suffix가 보존됩니다.

### ALB TargetGroup 패널

아래 SSM parameters가 추가되어 있으나 CloudWatch dashboard에 TargetGroup 패널이 없습니다.
후속 PR에서 `AWS/ApplicationELB` 섹션을 추가하세요.

- `/safespot/dev/front-edge/alb-arn-suffix`
- `/safespot/dev/front-edge/api-core-target-group-arn-suffix`
- `/safespot/dev/front-edge/api-public-read-target-group-arn-suffix`

### YACE static config 활성화

`values-dev-eks.yaml`의 YACE static 블록(SQS / Lambda)이 주석 처리된 상태입니다.
SQS queue 이름과 Lambda function 이름이 확정되었으므로 주석을 해제하고 실제 값으로 교체하세요.
