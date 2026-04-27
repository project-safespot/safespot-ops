# safespot-ops


# SafeSpot CI/CD & Infrastructure 구조

## 개요
GitHub Actions → Argo CD → Kubernetes로 이어지는 GitOps 기반 배포 구조

---

## 전체 흐름

```

1. 코드 변경 (push)
2. GitHub Actions 실행 (이미지 빌드 & push)
3. deployment.yaml 이미지 태그 업데이트
4. Git commit & push
5. Argo CD가 변경 감지
6. Kubernetes 자동 배포

```

---

## 디렉터리 구조 및 역할

### 1. `.github/workflows/`
**역할: CI (빌드 + 이미지 푸시 + manifest 업데이트)**

| 파일 | 대상 |
|------|------|
| api-deploy.yaml | api-core, api-public-read |
| worker-deploy.yaml | async-worker |
| ingestion-deploy.yaml | external-ingestion |
| monitoring-validate.yaml | monitoring 검증 |

**기능**
- Docker 이미지 빌드 및 GHCR push
- deployment.yaml image tag 자동 변경
- Git 재커밋 → ArgoCD 트리거
- monitoring은 배포가 아닌 검증 전용

---

### 2. `argocd/`

#### 2-1. `projects/`
**역할: Argo CD 프로젝트 설정**

- 허용 repository 정의
- 배포 가능한 namespace 정의
- RBAC (developer / ci 권한)

---

#### 2-2. `applications/`
**역할: 배포 단위 정의 (핵심)**

| Application | Namespace | 대상 |
|------------|----------|------|
| api-core | application | API |
| api-public-read | application | Read API |
| external-ingestion | application | 외부 데이터 수집 |
| async-worker | worker | 비동기 처리 |
| postgres | safespot-db | DB |
| redis | safespot-cache | Cache |
| localstack | safespot-localstack | SQS/Lambda (로컬) |
| monitoring | monitoring | Prometheus/Grafana |

**기능**
- Git 경로 → Kubernetes 리소스 매핑
- 자동 sync (Git 변경 시 자동 배포)

---

### 3. `apps/`
**역할: 애플리케이션 Kubernetes 리소스 정의**

구성:
```

deployment.yaml
service.yaml
configmap.yaml
secret.example.yaml
ingress.yaml
hpa.yaml

```

**대상 서비스**
- api-core
- api-public-read
- external-ingestion
- async-worker

---

### 4. `data/`
**역할: 데이터 계층 관리**

#### postgres/
- DB schema (initdb)
- Helm values
- DB 설정

#### redis/
- Redis 설정
- Helm values

---

### 5. `async/`
**역할: 비동기 인프라 (로컬 테스트)**

- LocalStack 기반 SQS / Lambda
- queue / lambda 초기화

---

### 6. `monitoring/`
**역할: 관측 (Observability) 전체 관리**

#### 6-1. values.yaml
- Prometheus / Grafana 설정
- ServiceMonitor / Rule selector 정의

---

#### 6-2. resources/servicemonitors/
**역할: 메트릭 수집 대상 정의**

- 수집 endpoint: `/actuator/prometheus`
- 수집 주기: 15s

---

#### 6-3. resources/prometheusrules/
**역할: 알람 조건 정의**

| 영역 | 예시 |
|------|------|
| Application | Pod 상태, CrashLoop |
| Redis | 메모리, 연결 수 |
| PostgreSQL | 연결 수, deadlock |
| Worker | Pod 상태 |
| Kubernetes | CPU, Memory |
| JVM | Heap, GC |

---

#### 6-4. resources/dashboards/
**역할: Grafana 대시보드 정의**

- safespot-overview
- safespot-application
- safespot-redis
- safespot-worker
- safespot-jvm

---

### 7. `README.md`
**역할: 전체 구조 및 사용법 설명**

---

## 전체 구조 요약

| 영역 | 역할 |
|------|------|
| workflows | CI (빌드 + 이미지 + manifest 수정) |
| argocd | CD (배포 정의 + 자동 sync) |
| apps | 서비스 실행 정의 |
| data | DB / Redis |
| async | SQS / Lambda (로컬) |
| monitoring | 메트릭 / 알람 / 대시보드 |

---

## 핵심 특징

- GitOps 기반 배포 (Argo CD)
- 이미지 태그 = commit SHA (latest 미사용)
- manifest 자동 업데이트
- monitoring은 CI에서 검증만 수행 (배포는 ArgoCD 담당)
- ServiceMonitor / PrometheusRule / Dashboard 완전 분리 구조
