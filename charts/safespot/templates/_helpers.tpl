{{/*
===============================================================================
공통 리소스 라벨 정의
-------------------------------------------------------------------------------
모든 Kubernetes 리소스(metadata.labels)에 공통으로 붙는 라벨 집합

목적:
- 리소스 그룹핑 (kubectl, Prometheus, Grafana 필터링)
- 환경(dev/prod) 구분
- 릴리즈(모니터링/애플리케이션) 구분
- Helm 관리 리소스 식별

사용 예:
metadata:
  labels:
    {{- include "safespot-ops.labels" . | nindent 4 }}
===============================================================================
*/}}
{{- define "safespot-ops.labels" -}}
app.kubernetes.io/part-of: safespot
app.kubernetes.io/managed-by: Helm
env: {{ .Values.global.env | quote }}
region: {{ .Values.global.region | quote }}
release: {{ .Values.global.releaseLabel | quote }}
{{- end }}


{{/*
===============================================================================
Grafana Dashboard 자동 등록용 라벨 정의
-------------------------------------------------------------------------------
Grafana sidecar가 ConfigMap을 dashboard로 인식하도록 하는 라벨

목적:
- Grafana가 ConfigMap을 dashboard로 자동 로드하도록 트리거
- dashboard 관리 자동화

필수 조건:
- kube-prometheus-stack의 Grafana sidecar 활성화되어 있어야 함

사용 예:
metadata:
  labels:
    {{- include "safespot-ops.dashboardLabels" . | nindent 4 }}

결과 예:
grafana_dashboard: "1"
===============================================================================
*/}}
{{- define "safespot-ops.dashboardLabels" -}}
{{ .Values.global.grafanaDashboardLabel }}: {{ .Values.global.grafanaDashboardLabelValue | quote }}
{{- end }}


{{/*
===============================================================================
PrometheusRule 공통 라벨 정의
-------------------------------------------------------------------------------
Prometheus가 PrometheusRule을 인식하도록 release 라벨 포함

사용 예:
metadata:
  labels:
    {{- include "safespot-ops.ruleLabels" . | nindent 4 }}
===============================================================================
*/}}
{{- define "safespot-ops.ruleLabels" -}}
{{- include "safespot-ops.labels" . }}
app.kubernetes.io/component: alerting
{{- end }}