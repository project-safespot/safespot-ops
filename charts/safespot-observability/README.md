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

## Grafana Image Renderer

Grafana dashboard/panel의 PNG 이미지 렌더링을 위한 sidecar 서비스입니다.
부하테스트 결과 스냅샷, 장애 리포트, 공유 링크(rendered image) 생성에 사용합니다.

### 구현 방식 (현재)

chart 내장 `imageRenderer`를 사용하지 않고, `extraObjects`로 renderer Deployment/Service를 직접 정의합니다.

**이유**: chart liveness probe가 `httpGet` 고정이라 `tcpSocket`으로 override 불가. Grafana 13.0.1 production mode는 `renderer_token`이 비거나 기본값이면 기동 거부(`failed to start rendering service`). 따라서 non-empty `AUTH_TOKEN`을 유지하면서 kubelet probe 실패를 피하려면 `tcpSocket` probe가 유일한 해법이고, 이를 위해 built-in을 비활성화했습니다.

### 설정 위치

| 설정 | 위치 | 설명 |
|---|---|---|
| `imageRenderer.enabled: false` | `values.yaml` | chart 내장 renderer 비활성화 |
| `grafana.envValueFrom.GF_RENDERING_RENDERER_TOKEN` | `values-dev-eks.yaml` | Secret에서 renderer token 주입 |
| `grafana.env.GF_RENDERING_SERVER_URL/CALLBACK_URL` | `values-dev-eks.yaml` | renderer 연결 URL (수동 설정) |
| renderer Secret (`grafana-image-renderer-token`) | `values-dev-eks.yaml` `extraObjects` | AUTH_TOKEN 공유 Secret |
| renderer Deployment | `values-dev-eks.yaml` `extraObjects` | tcpSocket probe, ops 노드 배치 |
| renderer Service | `values-dev-eks.yaml` `extraObjects` | ClusterIP 8081 |

### 주의사항

1. **built-in `imageRenderer`는 `enabled: false` 유지**: probe override 불가 + Grafana 13.0.1 empty token 거부 문제로 사용하지 않습니다.
2. **token은 반드시 non-empty**: Grafana 13.0.1 production mode에서 `renderer_token`이 비거나 기본값이면 `failed to start rendering service`로 CrashLoopBackOff 발생.
3. **renderer token 운영화**: 현재 `values-dev-eks.yaml`의 `extraObjects[0].stringData.token`은 dev 임시 값입니다. 운영에서는 ExternalSecret(SSM `/safespot/<env>/observability/grafana/renderer-token`)으로 교체해야 합니다.
4. **GF_RENDERING_* URL은 release name에 종속**: `safespot-observability-dev-grafana-image-renderer` 등의 서비스명은 Helm release name(`safespot-observability-dev`)에서 파생됩니다. release name 변경 시 URL도 함께 수정해야 합니다.
5. **memory limit 주의**: Chromium 기반이므로 512Mi 이하는 OOMKill 발생 가능. 현재 1Gi 설정.
6. **renderer /render/version에서 401은 정상**: `AUTH_TOKEN`이 활성화되어 있으므로 token 없는 HTTP 요청은 401입니다. liveness/readiness probe는 `tcpSocket`을 사용하므로 401과 무관합니다.

### 검증 명령

```bash
# renderer Deployment/Service/Pod 상태
kubectl -n monitoring get deploy,svc,pod | grep -i renderer

# renderer probe 정상 여부 (tcpSocket — Liveness probe failed 없어야 함)
kubectl -n monitoring describe pod \
  $(kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana-image-renderer -o name | head -1 | cut -d/ -f2)

# renderer token Secret 확인 (non-empty 값이어야 함)
kubectl -n monitoring get secret grafana-image-renderer-token -o jsonpath='{.data.token}' | base64 -d; echo

# renderer /render/version — AUTH_TOKEN 없이 호출 시 401이 정상 (auth 유지 확인)
kubectl -n monitoring port-forward svc/safespot-observability-dev-grafana-image-renderer 18081:8081 &
curl -i http://localhost:18081/render/version

# renderer 로그 확인 (restart loop 없어야 함)
kubectl -n monitoring logs deploy/safespot-observability-dev-grafana-image-renderer --tail=50

# Grafana 본체 GF_RENDERING_* env 확인 (세 항목 모두 있어야 함)
kubectl -n monitoring exec deploy/safespot-observability-dev-grafana -- env | grep GF_RENDERING
# 기대:
# GF_RENDERING_SERVER_URL=http://safespot-observability-dev-grafana-image-renderer.monitoring:8081/render
# GF_RENDERING_CALLBACK_URL=http://safespot-observability-dev-grafana.monitoring:80/
# GF_RENDERING_RENDERER_TOKEN=safespot-dev-renderer-token-2025   ← non-empty

# Grafana UI 렌더 테스트
# Dashboard → Share → Direct link rendered image → 이미지 생성 확인
```

### 마이그레이션 노트 (이전 배포 정리)

이전 배포에서 `grafana-image-renderer-no-auth` Secret이 남아있을 수 있습니다. ArgoCD sync 후 해당 Secret이 자동 삭제되지 않으면 수동으로 제거합니다.

```bash
kubectl -n monitoring delete secret grafana-image-renderer-no-auth --ignore-not-found
```

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

## api-public-read fallback single-flight metrics

`api-public-read`는 cache miss spike가 per-request DB fallback으로 이어지는 fallback storm을 줄이기 위해 per-key single-flight를 사용합니다.

적용 cache:

- `shelter_status`
- `disaster_messages`
- `disaster_detail`

Actuator에서 실제 metric 노출 여부를 확인합니다.

```bash
curl -s http://localhost:28080/api/public/actuator/prometheus \
  | grep -Ei 'single|flight|fallback'
```

Prometheus discovery query:

```promql
{__name__=~".*single.*|.*flight.*|.*fallback.*"}
```

실제 확인된 metric:

- `fallback_singleflight_join_total`
- `fallback_singleflight_leader_total`
- `fallback_suppressed_total`
- `safespot_cache_fallback_total`
- `safespot_db_fallback_queries_total`
- `safespot_db_fallback_seconds_count`
- `safespot_db_fallback_seconds_sum`
- `safespot_db_fallback_seconds_max`

해석:

- Leader는 실제 DB fallback을 수행한 요청입니다.
- Join은 동일 key에 대해 leader 결과를 기다린 follower 요청입니다.
- Suppressed는 single-flight join으로 DB fallback이 억제된 요청입니다.
- Suppression Ratio는 `join / (leader + join)`입니다.
- single-flight는 DB fallback 폭주를 줄이지만 cold miss latency 자체를 제거하지는 않습니다.
- stale serve는 아직 별도 후속 과제입니다.

14:34 500 TPS 테스트에서는 `disaster_messages` 경로에서 single-flight 효과가 확인되었습니다.

- `disaster_messages` cache fallback total: 395
- leader: 96
- join: 299
- suppression ratio: 약 75.7%

`shelter_status`는 14:34 테스트에서 miss가 없어 별도 miss storm 테스트가 필요합니다.

## ALB CloudWatch 메트릭 (YACE)

YACE가 `AWS/ApplicationELB` namespace에서 수집하는 메트릭과 Prometheus에서 조회되는 이름입니다.

> **검증 쿼리**: Prometheus Explore에서 `{__name__=~"aws_applicationelb_.*"}` 실행

### Prometheus 메트릭 이름 목록

| CloudWatch 메트릭 | 통계 | Prometheus 이름 | 설명 |
|---|---|---|---|
| `RequestCount` | Sum | `aws_applicationelb_request_count_sum` | ALB가 수신한 총 요청 수 (60s bucket) |
| `TargetResponseTime` | Average | `aws_applicationelb_target_response_time_average` | ALB → Target 평균 응답 시간 (초) |
| `TargetResponseTime` | Maximum | `aws_applicationelb_target_response_time_maximum` | ALB → Target 최대 응답 시간 (초) |
| `HTTPCode_ELB_4XX_Count` | Sum | `aws_applicationelb_httpcode_elb_4xx_count_sum` | ALB 자체가 반환한 4xx 수 |
| `HTTPCode_ELB_5XX_Count` | Sum | `aws_applicationelb_httpcode_elb_5xx_count_sum` | ALB 자체가 반환한 5xx 수 |
| `HTTPCode_Target_2XX_Count` | Sum | `aws_applicationelb_httpcode_target_2xx_count_sum` | Target이 반환한 2xx 수 (TargetGroup 별) |
| `HTTPCode_Target_4XX_Count` | Sum | `aws_applicationelb_httpcode_target_4xx_count_sum` | Target이 반환한 4xx 수 (TargetGroup 별) |
| `HTTPCode_Target_5XX_Count` | Sum | `aws_applicationelb_httpcode_target_5xx_count_sum` | Target이 반환한 5xx 수 (TargetGroup 별) |
| `TargetConnectionErrorCount` | Sum | `aws_applicationelb_target_connection_error_count_sum` | Target 연결 실패 수 (TargetGroup 별) |
| `RejectedConnectionCount` | Sum | `aws_applicationelb_rejected_connection_count_sum` | ALB가 거절한 연결 수 |
| `ActiveConnectionCount` | Sum | `aws_applicationelb_active_connection_count_sum` | 현재 활성 TCP 연결 수 |
| `NewConnectionCount` | Sum | `aws_applicationelb_new_connection_count_sum` | 신규 TCP 연결 수 |

> **주의**: YACE 버전에 따라 메트릭 이름 변환 규칙이 다를 수 있습니다. 실제 이름은 위의 검증 쿼리로 확인하세요.

### ALB TPS 계산 예시

```promql
# ALB TPS (초당 요청 수)
rate(aws_applicationelb_request_count_sum[1m])

# Application TPS (http_server_requests 기반)
sum(rate(http_server_requests_seconds_count{namespace="application"}[1m]))

# ALB TPS와 App TPS 비교 (갭 = ALB → App 구간 drop)
rate(aws_applicationelb_request_count_sum[1m])
  - sum(rate(http_server_requests_seconds_count{namespace="application"}[1m]))
```

### ALB dimension 레이블

YACE discovery로 수집된 메트릭에는 다음 레이블이 자동 추가됩니다.

| 레이블 | 예시 값 | 설명 |
|---|---|---|
| `dimension_LoadBalancer` | `app/safespot-dev-alb/abc123` | ALB ARN suffix |
| `dimension_TargetGroup` | `targetgroup/safespot-dev-tg/def456` | TargetGroup ARN suffix (TargetGroup 레벨 메트릭만) |
| `tag_Name` | `safespot-dev-alb` | ALB에 부여된 Name 태그 |

### ALB YACE 수집 설정 확인

1. `values-dev-eks.yaml` → `yace.config.discovery.jobs` 에서 `type: AWS/ApplicationELB` 두 개 job 확인
2. YACE IRSA 역할에 다음 권한 필요:
   - `elasticloadbalancing:DescribeLoadBalancers`
   - `elasticloadbalancing:DescribeTargetGroups`
   - `tag:GetResources`
   - `cloudwatch:GetMetricData`

### AWS CLI로 직접 확인

```bash
# CloudWatch에서 RequestCount 수집 가능 여부 확인
aws cloudwatch list-metrics \
  --region ap-northeast-2 \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount

# 특정 시간대 TPS 확인 (LoadBalancer dimension 값은 위 명령 결과에서 확인)
aws cloudwatch get-metric-statistics \
  --region ap-northeast-2 \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<LoadBalancer dimension value> \
  --start-time <UTC_START>  \
  --end-time <UTC_END> \
  --period 60 \
  --statistics Sum
```

## EKS dev 배포 절차

### EKS values 파일 적용 주의

EKS 배포에서는 반드시 `values-dev-eks.yaml`을 포함해야 합니다.

이 파일이 빠지면 api-core와 api-public-read ServiceMonitor scrape path가 기본값인 `/actuator/prometheus`로 남습니다. 두 서비스는 application context-path를 사용하므로 기본 path는 실제 actuator endpoint와 일치하지 않습니다.

기대 scrape path:

- api-core: `/api/core/actuator/prometheus`
- api-public-read: `/api/public/actuator/prometheus`
- external-ingestion: `/actuator/prometheus`

Tomcat metric 이름 확인용 탐색 쿼리:

```promql
{__name__=~"tomcat_threads_.*", namespace="application"}
```

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
