# OneK8s-argocd

**The delivery plane, as objects.** This repository decides *where* and *when*
the platform's applications are deployed: one Helm chart (`argocd/`) holding the
Argo CD `AppProject` and `ApplicationSet`s, and the [Kargo](https://kargo.io)
`Project`, `Warehouse` and `Stage`s that decide which build each of those
Applications runs.

It holds no application source, no chart of an application and no Terraform.
Four repositories, four jobs:

| Repository | Owns |
|---|---|
| [OneK8s](https://github.com/olljanat-ai/OneK8s) | The clusters and the platform: foundations, tenants, the Argo CD hub, Kargo, and the one root `Application` that points them here. |
| **OneK8s-argocd** (this one) | Where and when an application is deployed: the `AppProject`, the `ApplicationSet`s, the release path and the gate in front of production. |
| [OneK8s-fluxcd](https://github.com/olljanat-ai/OneK8s-fluxcd) | The same question — where and when — answered by Flux, per cluster, with no hub and no promotion engine. It runs beside this one on AKS and EKS, deploying the same charts to a different tenant, so the two shapes can be compared while running. |
| [OneK8s-hello](https://github.com/olljanat-ai/OneK8s-hello) | What is deployed: the example applications, their source, their Dockerfiles and their charts. **Both** delivery planes deploy these, unchanged. |

The split is the point. A developer changing `apps/hello/chart` in OneK8s-hello
never touches the delivery plane; a change to the delivery plane never rebuilds
an image; and the platform repository owns neither — it only says which
repository, revision and environment the delivery plane is bootstrapped from.

It is also what makes the comparison with OneK8s-fluxcd honest: that plane
deploys the same charts from the same repository, to the same clusters, and
neither plane needed a line of the other's. Nothing here changes because it
exists.

```
OneK8s                     this repository                      OneK8s-hello
──────                     ───────────────                      ────────────
gitops/root-app.tf
  └── Application ─ syncs ─▶ argocd/  (one Helm chart, no app named in it)
      platform-gitops        ├── AppProject onek8s-platform
      (values: environment,  ├── ClusterPromotionTask onek8s-promote  ← one, shared
       repos, revisions,     │
       domain, tenant,       │   ...then, per entry under "apps:"
       sql, kargo)           ├── Kargo Project onek8s-<app>
                             │     ├── Warehouse <app> ──── watches ──▶ image + chart
                             │     ├── Stage staging    ┐
                             │     ├── Stage production ┘ write stages/<app>/*.yaml
                             │     └── Role promoter ───── who may open the gate
                             └── ApplicationSet <app>-<stage> ──▶ sync apps/*/chart
                                                                  at the promoted revision
```

Every template ranges over `apps:`; none of them names an application. Adding
one is an entry in `argocd/values.yaml` — see [Adding an
application](#adding-an-application), which CI enforces rather than merely
claims.

## The release path

`hello` is deployed twice, to two clouds that mean two different things:

| Stage | Cloud | Cluster | How it gets there | URL |
|---|---|---|---|---|
| `staging` | `azure` | AKS — the Argo CD hub, `in-cluster` | Kargo promotes every new build automatically | `https://azure-hello.<domain>` |
| `production` | `aws` | EKS — a registered spoke | **a person promotes it, and only from `staging`** | `https://aws-hello.<domain>` |

`db-hello` has no stages and no Kargo objects: its database is an Azure resource
and its identity is an Entra one, so it is deployed to Azure and nowhere else,
and only when the Azure foundation of that environment was applied with
`enable_sql = true`. An application with one cluster has no release *path*.

Stages are configuration, not template logic, and the templates never name an
application — `argocd/values.yaml`:

```yaml
apps:
  hello:
    release:                        # an app with this block gets a release path
      image:
        repository: ghcr.io/olljanat-ai/onek8s-hello/hello
        selectionStrategy: NewestBuild   # or SemVer, with a semverConstraint
        tagRegexes: [^sha-[0-9a-f]{7,40}$]   # immutable build tags only
    stages:
      staging:
        cloud: azure
        cluster: in-cluster    # the hub: named, because it has no cluster Secret
        promotedFrom: ""       # the Warehouse: new builds enter here
        autoPromotion: true
      production:
        cloud: aws             # a spoke: matched by label on the Secret gitops wrote
        promotedFrom: staging  # only what staging has already run
        autoPromotion: false   # the gate
        soakTime: ""           # e.g. "2h": how long it must have run in staging first
```

A stage that names a `cluster` is generated from a one-element list (that is how
the hub gets in — Argo CD's built-in `in-cluster` entry carries no Secret and so
cannot be selected by label). A stage that names only a `cloud` is generated by a
cluster generator matching `onek8s.io/cloud` and `onek8s.io/environment` on the
spokes' cluster Secrets, so a cloud that is not registered as a spoke in this
environment produces no `Application` at all.

## How a promotion works

Kargo's `Warehouse` watches two things — the image the build workflow pushes and
the chart it is deployed with — and freezes them together as a piece of
**Freight**. Freight is immutable: it names a tag and a commit, never "whatever
`main` says". Promoting a stage runs the steps in
the shared `ClusterPromotionTask` (`argocd/templates/kargo-promotion-task.yaml`)
that every Stage of every application delegates to, which writes that Freight
into this repository:

```
ghcr.io/…/hello:sha-a1b2c3d ─┐
                             ├─▶ Freight ──▶ Stage staging ──▶ commit:
apps/hello/chart @ 9f4e2b1 ──┘                                 stages/hello/staging.yaml
                                                                 chartRevision: 9f4e2b1
                                                                 image.tag: sha-a1b2c3d
                                    │
                              a person promotes
                                    ▼
                                Stage production ──▶ commit:
                                                     stages/hello/production.yaml
```

Both `ApplicationSet`s read those files back — `chartRevision` as the chart
source's `targetRevision`, `image.tag` as a Helm values file — so **what a
cluster runs is a line in Git**, and getting there means making a commit.

That is also why both Applications are auto-synced now. The gate in front of AWS
is no longer "Argo CD has been told not to apply this": it is that no commit says
production runs that build yet. Three properties follow, none of which the old
withheld-sync gate had:

- It cannot be lifted by editing the delivery plane. Adding a sync policy back
  changes nothing, because the Application is already synced — to the previous
  Freight.
- It covers the chart as well as the image. A chart change is part of the
  Freight, so it reaches production by promotion like everything else.
- It leaves a record where the change is: `git log stages/hello/production.yaml`
  names every build production has ever run, the Freight it came from and the
  person who asked for it.

## Promoting

Whatever opens the gate leaves the same commit behind, so use whichever is at
hand:

```bash
# The UI: Project onek8s-hello, Stage production, "Promote" on the Freight
open https://kargo.onek8s.lol

# The CLI
kargo login https://kargo.onek8s.lol --sso
kargo get freight --project onek8s-hello            # what staging has run
kargo promote   --project onek8s-hello --stage production --freight <name>
kargo get promotions --project onek8s-hello         # who promoted what, when

# No CLI, no UI: a Promotion is an ordinary object
kubectl -n onek8s-hello get stage staging -o jsonpath='{.status.freightHistory[0].items.*.name}'
```

Who may do it is `apps.<name>.promoters` in `argocd/values.yaml` (falling back to
`kargo.promoters`): a list of Entra ID group object IDs, rendered into a
`ServiceAccount` and a `Role` in **that application's** Project namespace,
granting `promote` on exactly the stages that wait for a person. One Kargo
Project per application is what makes that possible — and what stops two teams'
stages from colliding on the name `production`.
That list lives here, beside the Stage it guards, so changing the guest list is a
reviewed commit rather than a `terraform apply` — and it grants nothing else:
not editing a Stage, not changing what the Warehouse watches, not promoting in
another Project.

Two things make the gate hard to lose by accident:

- **CI asserts it.** `PR Validation` renders the chart and compares three
  objects against `apps.<name>.stages`, for **every** application with a release
  path — the `ProjectConfig`'s promotion policy, the `Stage`'s Freight sources,
  and the `ApplicationSet`'s Kargo authorization — and fails if any of them
  drifts, if no stage waits for a person, or if the one that does could take an
  unproven build straight from the Warehouse.
- **The file a promotion writes is the file Argo CD reads**, and CI checks that
  those two references still name the same path. A rename that updated only one
  of them would leave a stage frozen on whatever it last deployed, silently.

## What the hub has to have

Kargo runs on the hub and is installed by OneK8s' `foundations/azure/kargo.tf`
(`enable_kargo`). Two things are deliberately not installed with it, because
they are credentials rather than configuration:

1. **A Git credential that may push to this repository.** A promotion is a
   commit, so Kargo needs one. Create it in the Project's namespace, or in the
   cluster's shared-credentials namespace to serve every Project:

   ```bash
   kubectl -n kargo-shared-resources create secret generic onek8s-argocd-repo \
     --from-literal=repoURL=https://github.com/olljanat-ai/OneK8s-argocd.git \
     --from-literal=username=<user or app-id> \
     --from-literal=password=<PAT or installation token>
   kubectl -n kargo-shared-resources label secret onek8s-argocd-repo \
     kargo.akuity.io/cred-type=git
   ```

   A fine-grained PAT with *contents: read and write* on this repository alone is
   enough; a GitHub App installation is the better long-lived answer.

2. **A webhook secret**, if you want a push to be noticed immediately instead of
   on the Warehouse's `interval` (5 minutes). Set `kargo.webhook.enabled=true`,
   create the named Secret in the Project's namespace, and point a GitHub webhook
   at the receiver's URL (`kubectl -n onek8s-hello get projectconfig onek8s-hello
   -o jsonpath='{.status.webhookReceivers}'`).

Nothing else is manual. There is no Argo CD API account and no bearer token
anywhere in the promotion path any more: Kargo writes `Application` objects as a
controller, through the Kubernetes API, under RBAC the chart installs.

## What Terraform passes in

The chart is never rendered with its own defaults in a deployed environment.
OneK8s' `gitops/root-app.tf` creates one `Application` on the hub pointing at
`argocd/` here and hands it the environment's facts as Helm values:

| Value | From |
|---|---|
| `environment` | `var.environment` — selects the spokes and labels everything |
| `repoURL`, `targetRevision` | this repository, `var.platform_apps` |
| `appsRepoURL`, `appsTargetRevision` | the applications' repository, `var.platform_apps` |
| `argocdNamespace` | the hub foundation's output |
| `domain` | the platform wildcard, `var.platform_apps.domain` |
| `tenant` | the namespace the tenants stack created |
| `sql.server`, `sql.database` | the Azure foundation's outputs — empty means no `db-hello` |
| `kargo.enabled`, `kargo.namespace`, `kargo.url` | the hub foundation's outputs — `enabled` is false when the hub has no Kargo, and then no promotion object is rendered at all |

That is what lets one copy of this chart serve `prototype`, `dev`, `staging` and
`prod`: nothing environment-specific is committed here.

> The platform environment (`prototype`, …) and an application stage (`staging`,
> `production`) are different axes. One platform environment contains both the
> Azure staging cluster and the AWS production cluster of the `hello` app.

## Working on it

```bash
helm lint argocd
helm template platform-gitops argocd | less

# as a deployed environment renders it, database and all
helm template platform-gitops argocd \
  --set sql.server=sql-onek8s-prototype-ab12.database.windows.net \
  --set sql.database=appdb

# as a hub without Kargo renders it: Argo CD objects, no promotion objects.
# The stage files are still read, so it deploys the last thing that was
# promoted — losing the engine costs you promotions, not the deployment.
helm template platform-gitops argocd --set kargo.enabled=false

# as a second application onboarded purely in values renders it
helm template platform-gitops argocd -f tests/onboarding-values.yaml
```

Nothing here is applied by hand: merging to `main` is what deploys it, because
the root Application syncs this repository.

`stages/` is the exception: it is written by Kargo, and editing it by hand
deploys something no Freight names. The next promotion overwrites it.

## Adding an application

An entry under `apps:` in `argocd/values.yaml`, and nothing else — no template,
no Warehouse file, no copy of the promotion steps:

```yaml
apps:
  checkout:
    enabled: true
    chartPath: apps/checkout/chart      # in the applications repository
    repoURL: ""                         # or another repo; it is allow-listed automatically
    hostPrefix: checkout                # "<cloud>-checkout.<domain>"
    requires: []                        # values that must be non-empty to render at all
    parameters:                         # this app's own; rendered with .cloud/.stage/.Values
      welcomeMessage: Hello from {{ .cloud }}
    release:                            # omit for an app with a single cluster
      image:
        repository: ghcr.io/…/checkout
        selectionStrategy: SemVer       # or NewestBuild for sha-tagged builds
        semverConstraint: ^1.0.0
      interval: 5m
    promoters: ["<entra group object id>"]
    stages:
      staging:    { cloud: azure, cluster: in-cluster, promotedFrom: "",        autoPromotion: true  }
      production: { cloud: aws,                        promotedFrom: staging,   autoPromotion: false }
```

Then create the seed files the stages read — `stages/checkout/staging.yaml` and
`production.yaml`, each `chartRevision: main` and an empty `image.tag` — and the
application has a Kargo Project of its own, a Warehouse, two Stages, two
auto-synced Applications and its own promoter Role.

Three properties are worth knowing before you rely on them:

- **The promotion procedure is not copied.** Every Stage delegates to the one
  `ClusterPromotionTask`, so fixing how promotion works is one commit however
  many applications there are.
- **Applications are isolated.** One Kargo Project each: separate namespace,
  separate Freight, separate promoters, and no collision between two teams'
  `production` stages.
- **CI proves both.** `tests/onboarding-values.yaml` is a second application
  expressed exactly as above and deployed nowhere; the `a new application is
  values-only` job renders the chart with it and fails if a whole release path
  did not appear, if the new application got someone else's promoter rights, or
  if a second `ClusterPromotionTask` showed up.

An application with **one** cluster — like `db-hello`, whose database and
identity are Azure resources — omits `release` entirely. It gets an
auto-synced Application tracking `appsTargetRevision` and no Kargo objects at
all: an application with one stage has no release *path*, and a Warehouse in
front of it would be ceremony rather than a gate.

## Boundaries the AppProject enforces

Every Application here belongs to the `onek8s-platform` project, which allows
only the platform's own repositories, only the tenant namespace, and **no
cluster-scoped resources at all**. That last one is the mechanism behind the
platform's convention that tenant onboarding — namespaces, quotas,
SecretStores — stays in Terraform and only workloads belong in GitOps: an
Application that tried to manage a `Namespace` is refused by Argo CD rather than
quietly fighting the tenants stack over it.

The Kargo objects are not in that project: they are brought in by the root
Application itself, which is in `default`, because a Kargo `Project` is
cluster-scoped and creates the namespace its `Stage`s live in.
