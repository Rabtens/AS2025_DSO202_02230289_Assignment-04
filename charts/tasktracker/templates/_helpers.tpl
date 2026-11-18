{{- /*
  File        : charts/tasktracker/templates/_helpers.tpl
  Assignment  : DSO202 Assignment 4
  Purpose     : Named templates shared by every object. No object is produced here.
*/ -}}
{{- define "task-tracker.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-tracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Required, so nothing renders without an environment. */}}
{{- define "task-tracker.environment" -}}
{{- required "environment must be set (dev or staging): see environments/<env>/values.yaml" .Values.environment }}
{{- end }}

{{/* Required: the chart never renders a Secret (C3), it only refers to one. */}}
{{- define "task-tracker.secretName" -}}
{{- required "existingSecret must name a Secret created by the platform layer" .Values.existingSecret }}
{{- end }}

{{/* Common labels. Never used in selectors. */}}
{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" . }}
app.kubernetes.io/name: {{ include "task-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
dso202/environment: {{ include "task-tracker.environment" . | quote }}
{{- end }}

{{/* "<repository>:<tag>". The tag always comes from values (C1). */}}
{{- define "task-tracker.image" -}}
{{- printf "%s:%s" .repository (required "image.tag must be set" .tag) }}
{{- end }}
