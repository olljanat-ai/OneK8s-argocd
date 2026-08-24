{{/*
Helpers shared by every template here. They exist so that the templates can
range over .Values.apps without any of them naming an application: the cost of
onboarding one is an entry in values.yaml, not a copy of a file.

Every helper takes a dict rather than a scalar, because they all need the root
context (.Values, for an application's requirements and for tpl) alongside the
application and, where relevant, the stage.
*/}}

{{/*
Is this application rendered at all?

"enabled" is the switch; "requires" is the interesting half. It lists dotted
paths into these values that must be non-empty — db-hello names sql.server and
sql.database, so an environment whose Azure foundation was applied with
enable_sql = false renders no db-hello anything: no Application, no Kargo
objects, and nothing to keep in sync between the two. The application follows
the fact rather than a second switch somebody has to remember to flip.

Returns "true" or "".
*/}}
{{- define "onek8s.appEnabled" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $ok := $app.enabled -}}
{{- range $path := (default (list) $app.requires) -}}
  {{- $v := $root.Values -}}
  {{- range $key := splitList "." $path -}}
    {{- if kindIs "map" $v -}}
      {{- $v = index $v $key -}}
    {{- else -}}
      {{- $v = "" -}}
    {{- end -}}
  {{- end -}}
  {{- if not $v -}}{{- $ok = false -}}{{- end -}}
{{- end -}}
{{- if $ok -}}true{{- end -}}
{{- end -}}

{{/*
Does this application travel a release path? An application with a "release"
block is deployed from "stages/<app>/<stage>.yaml" — the file a promotion
writes; one without it is deployed straight from appsTargetRevision.

Deliberately independent of whether Kargo is installed. The file is committed
either way, so a hub with kargo.enabled = false still deploys the last thing
that was promoted, and a person can move a stage by editing it. Losing the
promotion engine should cost you promotions, not the deployment.
*/}}
{{- define "onek8s.hasRelease" -}}
{{- if .app.release -}}true{{- end -}}
{{- end -}}

{{/*
Is this application's release path actually driven by Kargo? Everything Kargo —
the Project, the Warehouse, the Stages, and the annotation that authorizes a
Stage to sync an Application — hangs off this rather than off "hasRelease", so a
hub without Kargo renders Argo CD objects and no promotion objects.
*/}}
{{- define "onek8s.kargoManaged" -}}
{{- if and .root.Values.kargo.enabled .app.release -}}true{{- end -}}
{{- end -}}

{{/*
Is this stage's cluster reached through an argocd-agent agent?

It follows from the topology rather than from a per-stage switch, and from the
same fact the cluster generator reads: a stage that names a "cluster" is the hub
(there is exactly one, "in-cluster", and the hub is the principal, not an
agent), while a stage that names only a "cloud" is a spoke — and every spoke is
attached by an agent now.

Returns "true" or "".
*/}}
{{- define "onek8s.agentManaged" -}}
{{- if and .root.Values.agent.enabled (not .cfg.cluster) -}}true{{- end -}}
{{- end -}}

{{/* The Kargo Project (and its namespace) of one application. */}}
{{- define "onek8s.kargoProject" -}}
{{- printf "%s-%s" .root.Values.kargo.projectPrefix .name -}}
{{- end -}}

{{/* Which applications repository an application's chart comes from. */}}
{{- define "onek8s.appsRepoURL" -}}
{{- default .root.Values.appsRepoURL .app.repoURL -}}
{{- end -}}

{{/*
The file a promotion writes and the ApplicationSet reads back:
"<stagesPath>/<app>/<stage>.yaml", relative to the root of this repository.
Both references are rendered from this one helper, so they cannot drift apart —
and PR validation asserts that they still agree in the rendered output, because
a rename that updated only one of them would leave a stage frozen on whatever
it last deployed.
*/}}
{{- define "onek8s.stageFile" -}}
{{- printf "%s/%s/%s.yaml" .root.Values.kargo.stagesPath .name .stage -}}
{{- end -}}

{{/*
The Helm parameters one Application is rendered with.

Four are passed to every application, because they are the platform's answer to
"where did this land" rather than anything an application chose. The rest come
from apps.<name>.parameters and are rendered as templates with .cloud, .stage,
.app and .Values in scope — which is how a value that genuinely differs per
cloud (hello's secret key: a path on Secrets Manager, a flat name everywhere
else) is resolved by the platform and handed to the chart finished, instead of
being an "if aws" inside somebody's chart.
*/}}
{{- define "onek8s.helmParameters" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $cloud := .cloud -}}
{{- $ctx := dict
      "Values" $root.Values "Chart" $root.Chart "Release" $root.Release "Template" $root.Template
      "cloud" $cloud "stage" .stage "app" $app "name" .name -}}
- name: cloud
  value: {{ $cloud | quote }}
- name: environment
  value: {{ $root.Values.environment | quote }}
- name: tenant
  value: {{ $root.Values.tenant | quote }}
{{- /* One label deep, which is all the *.<domain> wildcard covers. */}}
- name: ingress.host
  value: {{ printf "%s-%s.%s" $cloud $app.hostPrefix $root.Values.domain | quote }}
{{- range $key, $value := (default (dict) $app.parameters) }}
- name: {{ $key | quote }}
  value: {{ tpl (toString $value) $ctx | trim | quote }}
{{- end }}
{{- end -}}

{{/*
Where a stage's Application is deployed, as an ApplicationSet generator.

This follows from the topology rather than from the stage. The hub has no
cluster Secret and therefore no labels to select on, so it is named
("in-cluster") in a one-element list. A spoke is matched by the labels the
gitops stack put on the Secret it wrote — and a stage whose cloud is not
registered as a spoke in this environment generates nothing at all: there is no
cluster to deploy to, and nothing to keep in sync between the two.

Both halves produce the same parameter, "name", which is what the cluster
generator calls a cluster and what the Application's destination is written
from. The list spells it out by hand so that one destination expression serves
a named cluster and a selected one alike.

NEITHER GENERATOR MAY CONTAIN A TEMPLATE, and that is not a style preference.
For a stage with a release path this generator is the second half of a matrix,
and a matrix renders each subsequent generator with the parameters of the ones
before it *before* running it. A "{{`{{ .name }}`}}" here — the usual way to
carry a cluster generator's name through its "values" block — is therefore
resolved against the git generator's parameters, which have no such key, and
with goTemplateOptions: [missingkey=error] the whole ApplicationSet fails:

  failed to get params for second generator in the matrix generator: ...
  map has no entry for key "name"

The stage then has no Application at all, which surfaces at the far end of the
release path as Kargo's argocd-update step reporting that it is "unable to find
Argo CD Application <app>-<stage>". Keep the cluster name in the Application
template, where the merged parameters of both generators are in scope.
*/}}
{{- define "onek8s.clusterGenerator" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- if $cfg.cluster }}
- list:
    elements:
      - name: {{ $cfg.cluster | quote }}
        cloud: {{ $cfg.cloud | quote }}
{{- else }}
- clusters:
    selector:
      matchLabels:
        onek8s.io/environment: {{ $root.Values.environment | quote }}
        onek8s.io/cloud: {{ $cfg.cloud | quote }}
{{- end }}
{{- end -}}
