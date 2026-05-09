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

## Prometheus Adapter / HPA custom metric

SafeSpot의 `api-public-read` 워크로드는 재난 상황에서 요청 수가 급증할 수 있으므로,
CPU 기반 HPA만으로는 확장 타이밍이 늦어질 수 있습니다.

Prometheus Adapter는 Prometheus에 저장된 애플리케이션 메트릭을 Kubernetes HPA가 사용할 수 있는
`external.metrics.k8s.io` API 형태로 변환하는 역할을 수행합니다.

현재 사용 중인 metric 흐름은 다음과 같습니다.

- Prometheus/Grafana 원본 metric: `http_request_per_second_count`
- HPA external metric: `http_request_per_second`

이름 관계:

| 구분 | Metric name |
|---|---|
| Prometheus/Grafana 원본 metric | `http_request_per_second_count` |
| HPA external metric | `http_request_per_second` |

주의:

- `http_requests_per_second` 와 같은 plural 형태는 사용하지 않습니다.
- HPA는 반드시 `http_request_per_second` metric만 사용해야 합니다.

흐름:

```text
api-public-read /actuator/prometheus
  → Prometheus scrape
  → http_request_per_second_count 저장
  → Prometheus Adapter rule
  → rate() 계산
  → external.metrics.k8s.io
  → HPA가 http_request_per_second 기준으로 replica 조정
```

Prometheus/Grafana에서 보는 `http_request_per_second_count`는 애플리케이션 관측용 counter metric입니다.

Prometheus Adapter는 해당 counter metric에 `rate()`를 적용하여,
Kubernetes HPA가 사용할 external metric `http_request_per_second`를 생성합니다.

Prometheus Adapter 예시 설정:

```yaml
prometheus-adapter:
  rules:
    default: false
    external:
      - seriesQuery: 'http_request_per_second_count{namespace="application",service="api-public-read"}'
        resources:
          overrides:
            namespace:
              resource: namespace
        name:
          matches: "http_request_per_second_count"
          as: "http_request_per_second"
        metricsQuery: >
          sum(rate(http_request_per_second_count{
            namespace="application",
            service="api-public-read"
          }[1m]))
```

HPA metric 예시:

```yaml
metrics:
  - type: External
    external:
      metric:
        name: http_request_per_second
      target:
        type: AverageValue
        averageValue: "50"
```

검증 명령:

```bash
# Adapter API 등록 확인
kubectl get apiservice | grep metrics

# External metric 조회
kubectl get --raw \
  "/apis/external.metrics.k8s.io/v1beta1" | jq

# 특정 metric 조회 예시
kubectl get --raw \
  "/apis/external.metrics.k8s.io/v1beta1/namespaces/application/http_request_per_second" | jq

# Prometheus metric 확인
kubectl -n monitoring port-forward svc/safespot-observability-kube-prometheus 9090
```

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

### 5. 배포

```bash
helm upgrade --install safespot-observability charts/safespot-observability \
  -n monitoring --create-namespace \
  -f charts/safespot-observability/values-dev-eks.yaml \
  -f charts/safespot-observability/values-dev.infra.generated.yaml
```
