{{/*
Common labels applied to all resources.
*/}}
{{- define "openfire.labels" -}}
app: openfire
app.kubernetes.io/name: openfire
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/component: xmpp-server
app.kubernetes.io/managed-by: helm
{{- end }}

{{/*
Selector labels used in matchLabels and pod templates.
Must be a stable subset of the common labels.
*/}}
{{- define "openfire.selectorLabels" -}}
app: openfire
app.kubernetes.io/name: openfire
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
In-cluster service FQDN (default for xmpp.domain / xmpp.fqdn).
*/}}
{{- define "openfire.serviceFqdn" -}}
{{ .Release.Name }}-openfire.{{ .Values.namespace.name }}.svc.cluster.local
{{- end }}

{{/*
Server FQDN: what clients resolve. Drives the Kerberos SPN (xmpp/<fqdn>@REALM)
and the certificate CN.
*/}}
{{- define "openfire.fqdn" -}}
{{ .Values.xmpp.fqdn | default (include "openfire.serviceFqdn" .) }}
{{- end }}

{{/*
XMPP domain (user JIDs: user@domain).
*/}}
{{- define "openfire.xmppDomain" -}}
{{ .Values.xmpp.domain | default (include "openfire.serviceFqdn" .) }}
{{- end }}

{{/*
Kerberos service principal.
*/}}
{{- define "openfire.krbPrincipal" -}}
{{ .Values.kerberos.principal | default (printf "xmpp/%s@%s" (include "openfire.fqdn" .) .Values.kerberos.realm) }}
{{- end }}
