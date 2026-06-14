# safespot-ops

## Purpose

본 저장소는 SafeSpot 팀 프로젝트의 운영 관측 구성을 보존하기 위한 저장소입니다. SafeSpot은 프로젝트 당시 AWS 기반으로 구축 및 검증되었고, 프로젝트 종료 후 비용 방지를 위해 운영 리소스는 정리되었습니다.

이 저장소는 현재 운영 상태를 나타내기보다, 당시 사용했던 observability 차트와 GitOps 배포 구성을 재현 근거로 남기는 목적에 가깝습니다.

## Project status

- 현재 접속 가능한 Grafana, Prometheus, Alertmanager, CloudWatch 대시보드를 전제하지 않습니다.
- 실제 클러스터와 AWS 리소스는 정리되었으므로, README의 구성 설명은 운영 현황이 아니라 구현 근거 문서입니다.

## Repository structure

- `charts/safespot-observability`
  SafeSpot용 observability Helm chart입니다.
- `argocd/applications/observability-dev.yaml`
  observability chart를 `monitoring` 네임스페이스로 배포하는 ArgoCD Application입니다.
- `argocd/applications/fluent-bit-dev.yaml`
  Fluent Bit를 별도 ArgoCD Application으로 배포하는 설정입니다.
- `scripts/render-dev-values.sh`
  SSM Parameter 기반으로 `values-dev.infra.generated.yaml`을 생성하는 스크립트입니다.

## Verified configuration scope

### Prometheus / Grafana / Alertmanager

- `kube-prometheus-stack` 서브차트를 사용합니다.
- `values.yaml`, `values-dev-eks.yaml`에서 Grafana, Prometheus, Alertmanager 서비스/스토리지/리소스 설정이 확인됩니다.
- Grafana는 dashboard sidecar를 사용하며, dashboard ConfigMap 템플릿이 `templates/dashboards/` 아래에 있습니다.
- Alertmanager는 Slack receiver와 route 구성이 `values-dev-eks.yaml`에 포함되어 있습니다.

### Dashboards and rules

- Grafana dashboard ConfigMap 템플릿이 아래 경로에 있습니다.
  - `templates/dashboards/dashboard-api-core-configmap.yaml`
  - `templates/dashboards/dashboard-api-public-read-configmap.yaml`
  - `templates/dashboards/dashboard-app-overview-configmap.yaml`
  - `templates/dashboards/dashboard-cloudwatch-configmap.yaml`
  - `templates/dashboards/dashboard-eks-configmap.yaml`
  - `templates/dashboards/dashboard-loadtest-configmap.yaml`
  - `templates/dashboards/dashboard-redis-configmap.yaml`
- PrometheusRule 템플릿도 `templates/rules/` 아래에 있으며, API HTTP, Redis, EKS 규칙이 확인됩니다.

### CloudWatch / logging

- Grafana에는 CloudWatch datasource가 `values-dev-eks.yaml`에 정의되어 있습니다.
- YACE(`yet-another-cloudwatch-exporter`)가 활성화되어 있으며, RDS, ElastiCache, Application Load Balancer, SQS, Lambda 관련 CloudWatch metric 수집 구성이 포함됩니다.
- Fluent Bit는 CloudWatch Logs output을 사용하도록 설정되어 있습니다.
- 두 구성 모두 IRSA annotation을 전제로 하며, 실제 ARN 값은 generated values에서 주입되도록 설계되어 있습니다.

### HPA external metric

- `prometheus-adapter`가 활성화되어 있습니다.
- `http_server_requests_seconds_count`를 기반으로 `http_request_per_second` external metric을 노출하는 rule이 `values-dev-eks.yaml`에 정의되어 있습니다.
- 이 설정은 Kubernetes HPA의 `external.metrics.k8s.io` 사용을 전제로 한 구성 근거입니다.

## GitOps flow

- observability chart는 ArgoCD가 이 저장소의 `charts/safespot-observability` 경로를 직접 배포합니다.
- 배포 시 `values-dev-eks.yaml`과 `values-dev.infra.generated.yaml`을 함께 사용하도록 되어 있습니다.
- Fluent Bit는 별도 ArgoCD Application에서 upstream chart를 참조해 `logging` 네임스페이스에 배포합니다.

## Notes for reproduction

- `values-dev.infra.generated.yaml`은 정적 문서가 아니라 환경 식별자를 주입하는 generated 파일입니다.
- 실제 재현에는 SSM Parameter, IRSA role ARN, Redis endpoint, SQS queue 이름, ALB/RDS/ElastiCache dimension 값이 다시 필요합니다.
- 루트 chart만으로 현재 클러스터가 복구되는 것은 아니며, EKS/IRSA/SSM/ArgoCD 선행 구성이 필요합니다.
