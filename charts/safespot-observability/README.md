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
`external.metrics.k8s.io` 또는 `custom.metrics.k8s.io` API 형태로 변환하는 역할을 수행합니다.

현재 사용 중인 metric 흐름은 다음과 같습니다.

- Prometheus source metric: `http_request_per_second_count`
- HPA exposed metric: `http_request_per_second`

흐름:

```text
api-public-read /actuator/prometheus
  → Prometheus scrape
  → http_request_per_second_count 저장
  → Prometheus Adapter rule
  → external.metrics.k8s.io 또는 custom.metrics.k8s.io
  → HPA가 http_request_per_second 기준으로 replica 조정
```

Prometheus Adapter를 사용하는 이유:

- 재난문자 발송 직후의 급격한 요청 증가를 CPU보다 빠르게 감지 가능
- `api-public-read`의 실제 트래픽 기반 autoscaling 가능
- CloudFront / Redis cache miss 증가 상황을 더 빠르게 흡수 가능
- Karpenter node scale-out 완료 전 초기 burst 구간 완충 가능

관련 metric 참고:

- Micrometer source metric: `http_server_requests_seconds_count`
- HPA 변환 대상 metric: `http_request_per_second`
- Prometheus query 예시:

```promql
sum(rate(http_server_requests_seconds_count{
  namespace="application",
  service="api-public-read"
}[1m]))
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

## ArgoCD 배포 (EKS dev)

ArgoCD Application manifest: `argocd/applications/observability-dev.yaml`

### Application 등록 및 첫 배포

```bash
# Application 등록
kubectl apply -f argocd/applications/observability-dev.yaml

# 첫 번째 sync — kube-prometheus-stack CRD 설치
argocd app sync safespot-observability-dev

# CRD 설치 후 두 번째 sync — CRD에 의존하는 리소스(PrometheusRule, ServiceMonitor 등) 생성
argocd app sync safespot-observability-dev
```

> **2회 sync 필요**: `kube-prometheus-stack`의 CRD(PrometheusRule, ServiceMonitor 등)는 첫 번째 sync에서 설치되고,
> 해당 CRD를 사용하는 리소스는 두 번째 sync에서 정상 적용됩니다.
> ArgoCD UI에서 첫 번째 sync 후 일부 리소스가 `OutOfSync` 또는 `SyncFailed` 상태로 남아 있으면 한 번 더 sync하세요.

### 이후 인프라 값 갱신 시

```bash
AWS_PROFILE=<profile> ./scripts/render-dev-values.sh
git add charts/safespot-observability/values-dev.infra.generated.yaml
git commit -m "chore: update dev infra generated values"
git push
# ArgoCD auto-sync 미설정 시 수동 sync:
argocd app sync safespot-observability-dev
```

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
