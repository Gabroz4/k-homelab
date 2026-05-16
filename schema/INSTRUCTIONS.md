# Operating the Cluster

A practical guide to running this homelab — how it works, how to change it, and how to fix it when it breaks. Written for future-me, alone, at 2 a.m.

---

## 0. The golden rule

**Git is the source of truth. The cluster is a copy of this repo.**

You never `kubectl apply`, `kubectl edit`, or `helm upgrade` a managed resource. Flux will revert it within 10 minutes — silently. Every change is: edit a YAML → commit → push. The cluster catches up on its own.

The only thing applied by hand is the Bitwarden access token (a chicken-and-egg bootstrap secret). Everything else flows through git.

---

## 1. How it all fits together

This is the part worth understanding deeply. Once the tree clicks, the whole cluster stops being magic.

### 1.1 The reconciliation loop

Flux runs a control loop. Forever, it:

1. **Fetches** the repo — the `GitRepository` resource polls `github.com/Gabroz4/k-homelab` on `main` every 1 minute. A GitHub push webhook also pokes it, so in practice a `git push` is reflected within seconds.
2. **Builds** — for each `Kustomization`, the kustomize-controller runs `kubectl kustomize` on its target directory to produce a flat stream of manifests.
3. **Substitutes** — `postBuild.substituteFrom` runs envsubst over that stream, replacing `${VAR}` with values from the `cluster-settings` ConfigMap.
4. **Applies** — the result is server-side-applied to the cluster.
5. **Prunes** — anything that was applied before but is no longer in the build output is **deleted** (`prune: true`). Removing a file from git removes the resource.

Drift is corrected the same way: if you hand-edit a managed resource, step 4 overwrites it back to what git says.

### 1.2 The Kustomization tree

There are **three tiers** of Flux `Kustomization`, each applying the next:

```
GitRepository/flux-system            polls ssh://git@github.com/Gabroz4/k-homelab @ main
│
└─ Kustomization/flux-system         path: ./clusters/homelab          ← TIER 1 (root)
   │   applies everything in clusters/homelab/:
   ├─ flux-system/                   Flux's own controllers (Flux manages itself)
   ├─ cluster-settings  (ConfigMap)  the per-site variables
   │
   ├─ Kustomization/infrastructure-configs       path: ./infrastructure/configs       ← TIER 2
   │     wait: true
   │     → namespaces · network-policies · upgrade-plans
   │
   ├─ Kustomization/infrastructure-controllers   path: ./infrastructure/controllers   ← TIER 2
   │     wait: true · dependsOn → infrastructure-configs
   │     → cert-manager · external-secrets · metallb · reflector · reloader ·
   │       snapshot-controller · sources · volsync · vpa · coredns
   │
   └─ Kustomization/apps                         path: ./apps                         ← TIER 2
         dependsOn → infrastructure-controllers
         │   applies one ks.yaml per app — and each ks.yaml IS another Kustomization:
         ├─ Kustomization/adguard      path: ./apps/adguard                            ← TIER 3
         ├─ Kustomization/nextcloud    path: ./apps/nextcloud    dependsOn → minio     ← TIER 3
         ├─ Kustomization/grafana      path: ./apps/grafana      dependsOn → prometheus
         ├─ Kustomization/alloy        path: ./apps/alloy        dependsOn → loki
         └─ … one per app, ~23 total
```

- **Tier 1** — created by `flux bootstrap`. It reconciles `clusters/homelab/`, whose `kustomization.yaml` lists `flux-system/`, `cluster-settings.yaml`, `infrastructure.yaml`, `apps.yaml`.
- **Tier 2** — `infrastructure.yaml` and `apps.yaml` *define* the `infrastructure-configs`, `infrastructure-controllers`, and `apps` Kustomizations. Tier 1 applies those definitions into the cluster.
- **Tier 3** — the `apps` Kustomization's job is **not** to deploy workloads directly. It applies `apps/<app>/ks.yaml`, and each of those is its own Flux `Kustomization` pointing at `./apps/<app>`. That per-app Kustomization is what actually deploys the workload.

Why the indirection for apps but not infrastructure? Because a per-app Kustomization gives each app **independent reconciliation** — its own retry, its own `dependsOn`, its own `postBuild` — so one broken app doesn't wedge the others. Infrastructure is small and tightly ordered, so two Kustomizations cover it.

### 1.3 The two things both called "Kustomization"

This trips everyone up. Two unrelated resources share the name:

| File | `apiVersion` | What it is |
|---|---|---|
| `apps/<app>/ks.yaml` | `kustomize.toolkit.fluxcd.io/v1` | A **Flux** Kustomization — a cluster object Flux reconciles on a schedule. |
| `apps/<app>/kustomization.yaml` | `kustomize.config.k8s.io/v1beta1` | A **Kustomize** kustomization — a build file listing `resources:`. Not a cluster object. |

Every app folder has **both**: `ks.yaml` says "Flux, reconcile this directory"; `kustomization.yaml` says "kustomize, here are the files in it".

### 1.4 The dependency graph

`dependsOn` makes a Kustomization wait until another is `Ready`. `wait: true` makes "Ready" mean *the workloads actually came up*, not just *the manifests applied*.

```
infrastructure-configs ──▶ infrastructure-controllers ──▶ apps
                                                            │
   prometheus ◀── backup, grafana, longhorn, nut-exporter, traefik
   minio      ◀── nextcloud
   loki       ◀── alloy
```

`prometheus`, `minio`, and `loki` carry `wait: true` because things genuinely depend on them being *up* (CRDs registered, S3 reachable). Every other app stays `wait: false` so reconciles finish fast.

### 1.5 Variable substitution

`cluster-settings` (`clusters/homelab/cluster-settings.yaml`) is one ConfigMap holding everything that varies per physical site — domain, timezone, LB range, hostPaths, the Pi's hostname. Every Kustomization with `postBuild.substituteFrom` gets `${VAR}` references replaced at apply time.

- Only `${VAR}` (braces) is substituted. Bare `$VAR` is left alone — safe for shell scripts in CronJobs.
- This is also a trap: see §10 on Grafana dashboards.

### 1.6 The lifecycle of one change

End to end, when you push a one-line edit to `apps/nextcloud/nextcloud-helmrelease.yaml`:

1. GitHub receives the push, fires the webhook at `flux-webhook.gabro.ovh`.
2. `notification-controller`'s `Receiver` tells the `GitRepository` to fetch *now*.
3. source-controller pulls the new commit, exposes it as an artifact.
4. kustomize-controller notices `apps` (and the per-app `nextcloud` Kustomization) point at a changed source — it rebuilds, substitutes, server-side-applies.
5. The `HelmRelease` object changes; helm-controller runs `helm upgrade nextcloud`.
6. New pods roll out. `task status` / `task bad` show the result.

No webhook? Same thing happens within ~1 min from the `GitRepository` poll, or instantly via `task reconcile`.

---

## 2. Everyday workflow

```bash
# 1. edit YAML files
# 2. smoke-test the build BEFORE pushing — a broken build wedges the whole tree
task build

# 3. commit + push (the user does this; review the diff first)
git add -A && git commit -m "…" && git push

# 4. watch it land
task status      # everything Ready?
task bad         # show only what's broken
```

If you don't want to wait for the webhook/poll: `task reconcile`.

---

## 3. Task reference

`task` (no args) lists everything. Full set:

| Task | What it does |
|---|---|
| `task build` | Kustomize-build `apps/` and `infrastructure/` — smoke test before every push. |
| `task reconcile` | Pull latest from git and reconcile all root Kustomizations now. |
| `task reconcile-ks name=<app>` | Reconcile one app Kustomization. |
| `task reconcile-hr ns=<ns> name=<rel>` | Reconcile one HelmRelease. |
| `task status` | Kustomizations, HelmReleases, and sources overview. |
| `task bad` | Only the resources that are **not** Ready, plus non-Running pods. |
| `task events` | Recent non-Normal events cluster-wide. |
| `task diff name=<ks> path=<dir>` | Preview what a Kustomization would change. |
| `task tree name=<ks>` | List every resource a Kustomization manages. |
| `task logs ns=<ns> name=<deploy>` | Follow a Deployment's logs. |
| `task restart ns=<ns> name=<deploy>` | `rollout restart` a Deployment and wait. |
| `task sync-es ns=<ns> name=<es>` | Force an ExternalSecret to re-sync from Bitwarden. |
| `task suspend ns=<ns> name=<rel>` | Pause Flux on a HelmRelease (for manual surgery). |
| `task resume ns=<ns> name=<rel>` | Resume Flux on a HelmRelease. |
| `task webhook-url` | Print the GitHub webhook URL. |

---

## 4. Adding a new service

### 4.1 Plain manifests (a Deployment, Service, etc.)

1. Create `apps/<app>/` with your manifests (`<app>.yaml`, `<app>-ingress.yaml`, …).
2. Add `apps/<app>/kustomization.yaml` listing them under `resources:`.
3. Add `apps/<app>/ks.yaml` — copy `apps/adguard/ks.yaml`, change `metadata.name` and `spec.path`. Add `dependsOn` only if it needs a CRD or another app first.
4. Add `<app>/ks.yaml` to `apps/kustomization.yaml`.
5. If it needs a **new namespace**, add it to `infrastructure/configs/namespaces/namespaces.yaml` with PSA labels (`baseline` unless it needs hostPath/host-namespaces — then `privileged`).
6. Add a NetworkPolicy file `infrastructure/configs/network-policies/<app>-policies.yaml` (default-deny, then the ingress/egress it needs).
7. `task build`, commit, push.

### 4.2 A Helm chart (HelmRelease)

1. Make sure the chart's repo exists in `infrastructure/controllers/sources/helmrepositories.yaml` — add a `HelmRepository` if not.
2. Create `apps/<app>/<app>-helmrelease.yaml`. Pin `spec.chart.spec.version`. Put all chart values inline under `spec.values:`.
3. `apps/<app>/kustomization.yaml` lists the HelmRelease (+ any sibling ExternalSecrets, ingress, VPA…). See `apps/alloy/` for the minimal shape.
4. Same `ks.yaml` + `apps/kustomization.yaml` wiring as above.
5. Prefer `existingSecret:` in chart values so the chart consumes an ESO-owned Secret instead of templating its own.

### 4.3 Conventions

- Restricted-compatible securityContext on anything new: `runAsNonRoot`, drop `ALL` caps, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`.
- No comments in YAML manifests — provenance lives in git history.
- Don't hardcode a value that already exists in `cluster-settings`; reference `${VAR}`.

---

## 5. Secrets

All secret values live in **Bitwarden Secrets Manager**. The cluster never stores plaintext secrets in git.

### 5.1 Adding a secret

1. In the Bitwarden UI, create the value with key `<namespace>/<secret-name>/<field>`.
2. Add an `ExternalSecret` — inline in the workload manifest for plain Deployments, or a sibling `*-externalsecret.yaml` file for Helm apps.
3. The filename **must** end in `-externalsecret.yaml` — `.gitignore` blocks anything with `secret`/`token`/`key`/`password` in the name, and only `*-externalsecret.yaml` is negated back in. (For any other file caught by this, add a `!`-negation to `.gitignore` and confirm with `git check-ignore -v <path>`.)

### 5.2 Rotating a secret

- **App-owned value** (OAuth secret, API token): change it in Bitwarden → `task sync-es ns=… name=…` → `task restart` consumers that read it as env vars (volume-mounted Secrets refresh on their own; Reloader handles many automatically).
- **Runtime-owned value** (Postgres / MinIO root / restic password): rotate it in the runtime *first*, then update Bitwarden — otherwise ESO overwrites the live Secret with a stale value and locks you out.

---

## 6. Networking a new service

- **Public** (`*.gabro.ovh`): create a Cloudflare tunnel, store its token in Bitwarden, add a tunnel Deployment under `apps/cloudflared/tunnels/`. TLS terminates at Cloudflare's edge, so the in-cluster Ingress is plain HTTP.
- **Local** (`*.local.gabro.ovh`): add an AdGuard DNS rewrite → Traefik's LB IP. The Ingress references `secretName: wildcard-local-tls` (Reflector mirrors the wildcard cert into every namespace). Traefik `IngressRoute`s use `entryPoints: [websecure]` + `tls: {}` and pick up the wildcard from the `default` `TLSStore`.
- **SSO**: attach the `forward-auth` Traefik middleware to the Ingress to gate it behind Authentik.

Every namespace is default-deny. A new external egress endpoint means editing that namespace's file in `infrastructure/configs/network-policies/`.

---

## 7. Debugging playbook

Start every investigation with `task bad` and `task events`.

### "I pushed but nothing changed"
`task status` → check the `GitRepository` revision matches your commit. If not, the webhook or git auth is the problem; force with `task reconcile`. If the revision is current but the Kustomization didn't apply, read on.

### A Kustomization is not Ready
```bash
flux get kustomizations -A
kubectl -n flux-system describe kustomization <name>
```
Common causes: a kustomize build error (run `task build` locally — it reproduces it), an envsubst failure (`missing closing brace` → an un-escaped `${...}`, see §10), or a prune blocked by a finalizer.

### A HelmRelease is stuck
```bash
flux get helmreleases -A
kubectl -n <ns> describe helmrelease <name>
kubectl -n flux-system logs deploy/helm-controller
```
- Retries exhausted → `flux -n <ns> reconcile helmrelease <name> --reset`, or `task suspend` then `task resume`.
- SSA field-manager conflict (adopting a release Helm installed) → set `spec.install.force` / `spec.upgrade.force: true` for one reconcile, then remove.

### A pod won't start
```bash
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> [--previous]
```
- `Pending` on the Pi → it lacks a toleration, or it has a Longhorn PVC (the Longhorn CSI driver is **not** on the Pi — `FailedAttachVolume`).
- `Pending` everywhere → resource pressure or a `nodeSelector` nothing satisfies.
- `CreateContainerConfigError` → a referenced Secret/ConfigMap doesn't exist yet (often a not-yet-synced ExternalSecret).

### An ExternalSecret won't sync
```bash
kubectl -n <ns> describe externalsecret <name>
kubectl -n external-secrets logs deploy/bitwarden-sdk-server
```
- `SecretSyncError` → the Bitwarden key path doesn't match `<ns>/<name>/<field>` exactly.
- Occasional `400` from Bitwarden cloud is normal flakiness — confirm by looking for a recent `200`; don't chase it as an auth bug.
- Force a retry: `task sync-es ns=… name=…`.

### A pod can't reach something
Almost always a NetworkPolicy. Every namespace is default-deny ingress **and** egress. Add the rule to that namespace's file in `infrastructure/configs/network-policies/`. Note: cross-node pods (Pi → API server) need both the ClusterIP and the node IP allowed; brand-new pods may fail for the first few seconds until policies are programmed.

### DNS / git fetch failing cluster-wide
If the `GitRepository` can't resolve GitHub, or public lookups `SERVFAIL`, suspect upstream-DNS pollution in the node's `/etc/resolv.conf` (a stale VPN/MagicDNS resolver). Restore `resolv.conf`, then restart CoreDNS.

---

## 8. Backups & restore

Backups are restic repositories on the 2 TB disk, served by an in-cluster restic REST server (`backup` namespace, append-only). DB dumps and VolSync write to it; `restic-prune` (admin creds) trims it weekly. See `README.md` for the layout.

**To restore**, run a throwaway restic pod with the repo URL and password (both from Bitwarden):

```bash
restic -r rest:http://<user>:<pass>@restic-rest-server.backup.svc.cluster.local:8000/<repo> snapshots
restic -r … restore latest --target /restore
```

Repos: `immich-files`, `immich-db`, `nextcloud-db`, `nextcloud-minio`, `authentik-db`. For the VolSync-managed PVCs (`immich-files`, `nextcloud-minio`), a `ReplicationDestination` restores a volume from the repo. DB dumps restore by piping the decompressed dump back into `psql`.

Test a restore occasionally — an untested backup is a rumour.

---

## 9. Upgrades

- **Images & charts** — Renovate opens PRs weekly (Mon 06:00). Digest and patch bumps auto-merge once CI (`kubeconform` + `flux-local`) passes; minor/major bumps are reviewed by hand. Don't bump versions manually.
- **k3s** — handled by the system-upgrade-controller via the `Plan`s in `infrastructure/configs/upgrade-plans/`. The agent Plan must tolerate the Pi's taint or its pod sits `Pending`.

---

## 10. Bootstrapping from zero on a new machine

1. **k3s** — install k3s on the x86 node. Optionally join the Pi as an agent with `--node-taint workload=stateless:NoSchedule`.
2. **Longhorn** — installed out-of-band (it is not in this repo's Flux tree); install it before the apps that need PVCs.
3. **Bitwarden** — create the org + access token; populate every `<ns>/<name>/<field>` key the `ExternalSecret`s reference.
4. **cluster-settings** — apply the ConfigMap *first* so `postBuild` substitutions resolve:
   `kubectl apply -f clusters/homelab/cluster-settings.yaml`
5. **Bitwarden access token** — apply the bootstrap Secret out-of-band:
   `kubectl -n external-secrets apply -f bitwarden-access-token.yaml`
6. **Flux** — `flux bootstrap github --owner=<owner> --repository=<repo> --branch=main --path=clusters/homelab --personal`. This regenerates `gotk-sync.yaml` with the new repo URL and starts the reconciliation loop.
7. **Cloudflare** — create the per-service tunnels, save tokens in Bitwarden, map `flux-webhook.<domain>` onto a tunnel → `webhook-receiver.flux-system.svc.cluster.local:80`.
8. **GitHub webhook** — `task webhook-url` prints it; add it to the repo's webhook settings with the HMAC secret from Bitwarden.

From there, Flux reconciles the whole cluster from git.

---

## 11. Gotchas — the things that have actually bitten

- **Two "Kustomization" kinds.** `ks.yaml` = Flux; `kustomization.yaml` = Kustomize. See §1.3.
- **`.gitignore` eats secret-ish filenames.** Anything matching `*secret*` / `*token*` / `*key*` / `*password*` is ignored. Name ExternalSecrets `*-externalsecret.yaml`; otherwise add a `!`-negation.
- **envsubst vs. literal `${...}`.** Flux substitutes every `${VAR}`. Grafana dashboard JSON uses `${...}` for its *own* templating — escape those as `$${...}` in the dashboard ConfigMaps, or the reconcile fails with `missing closing brace`. Bare `$VAR` is safe.
- **Never edit a managed resource live.** `kubectl edit` / `helm upgrade` is reverted at the next reconcile. Fix the YAML in git.
- **HPA-on-memory + VPA-on-memory fight.** They pin replicas at max. Pair HPA(CPU) with VPA(memory), never both on memory.
- **The Pi is special.** Soft affinity only (it can be unplugged anytime); needs the `workload=stateless` toleration; cannot run Longhorn-backed PVCs.
- **A broken `task build` wedges the whole tree.** Always run it before pushing.
