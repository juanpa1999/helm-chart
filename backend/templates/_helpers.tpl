{{/* Variables de entorno comunes al Deployment y al Job de migración. */}}
{{- define "backend.env" -}}
- name: DB_HOST
  value: {{ .Values.db.host | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* initContainer que bloquea hasta que PostgreSQL acepte conexiones. */}}
{{- define "backend.waitForDb" -}}
- name: wait-for-db
  image: {{ .Values.waitForDb.image }}
  command:
    - sh
    - -c
    - until pg_isready -h {{ .Values.db.host }} -p {{ .Values.db.port }}; do echo "waiting for db..."; sleep 2; done
{{- end }}

{{/* Contenedor que corre la migración (Job o initContainer). */}}
{{- define "backend.migrateContainer" -}}
- name: migrate
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    {{- toYaml .Values.migrations.command | nindent 4 }}
  env:
    {{- include "backend.env" . | nindent 4 }}
{{- end }}
