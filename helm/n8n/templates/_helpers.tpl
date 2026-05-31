{{- define "n8n.fullname" -}}
{{- .Release.Name }}
{{- end }}

{{- define "n8n.labels" -}}
app: {{ include "n8n.fullname" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "n8n.selectorLabels" -}}
app: {{ include "n8n.fullname" . }}
{{- end }}
