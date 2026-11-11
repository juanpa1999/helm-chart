{{/* Nombre del PVC de datos: persistence.claimName o <statefulsetName>-data. */}}
{{- define "db.pvcName" -}}
{{- default (printf "%s-data" .Values.statefulsetName) .Values.persistence.claimName -}}
{{- end }}
