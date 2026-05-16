
# Gabro's Homelab 🖥️

> A two-node k3s cluster (x86 primary + Raspberry Pi 5 for stateless workloads) with production-grade infrastructure — built to learn, experiment, and run self-hosted services. Fully GitOps-managed by Flux.

![k3s](https://img.shields.io/badge/k3s-lightweight_k8s-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-GitOps-5468FF?style=flat-square&logo=flux&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-ingress-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-tunnels-F38020?style=flat-square&logo=cloudflare&logoColor=white)
![Longhorn](https://img.shields.io/badge/Longhorn-storage-5F259F?style=flat-square)
![Helm](https://img.shields.io/badge/Helm-package_manager-0F1689?style=flat-square&logo=helm&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-monitoring-E6522C?style=flat-square&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-dashboards-F46800?style=flat-square&logo=grafana&logoColor=white)
![Loki](https://img.shields.io/badge/Loki-logs-F5A800?style=flat-square&logo=grafana&logoColor=white)
![MetalLB](https://img.shields.io/badge/MetalLB-load_balancer-4A90D9?style=flat-square)
![MinIO](https://img.shields.io/badge/MinIO-object_storage-C72E49?style=flat-square&logo=minio&logoColor=white)
![Authentik](https://img.shields.io/badge/Authentik-SSO-FD4B2D?style=flat-square)
![Bitwarden](https://img.shields.io/badge/Bitwarden-secrets_manager-175DDC?style=flat-square&logo=bitwarden&logoColor=white)
![AdGuard](https://img.shields.io/badge/AdGuard-DNS-68BC71?style=flat-square&logo=adguard&logoColor=white)
![Nextcloud](https://img.shields.io/badge/Nextcloud-self_hosted_cloud-0082C9?style=flat-square&logo=nextcloud&logoColor=white)
![Jellyfin](https://img.shields.io/badge/Jellyfin-media_server-00A4DC?style=flat-square&logo=jellyfin&logoColor=white)
![Immich](https://img.shields.io/badge/Immich-photo_backup-4250AF?style=flat-square)
![Navidrome](https://img.shields.io/badge/Navidrome-music_streaming-0D6EFD?style=flat-square)

---

## Cluster schema

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="schema/cluster-schema-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="schema/cluster-schema-light.png">
  <img alt="Cluster Schema" src="schema/cluster-schema-dark.png">
</picture>

---

## Hardware

Almost all hardware was recycled from previous upgrades, found laying around, or gifted by friends. The only purchases were the micro-ATX parts (mobo, case, PSU — cheapest available, student budget).

### Primary node (x86)

| Component    | Spec                |
| ------------ | ------------------- |
| CPU          | AMD Ryzen 5 2600X   |
| RAM          | 16 GB DDR4          |
| Boot / OS    | 1 TB Sabrent NVMe   |
| Storage NVMe | 500 GB Samsung NVMe |
| Media drive  | 4 TB HDD            |
| Backup drive | 2 TB HDD            |
| UPS          | 600 W               |

> Cloud storage services and the main OS run on the NVMe drives for speed.

### Stateless node (arm64)

| Component | Spec                              |
| --------- | --------------------------------- |
| Board     | Raspberry Pi 5 (arm64), 8 GB RAM  |
| Taint     | `workload=stateless:NoSchedule`   |

> The Pi only takes pods that explicitly tolerate the taint and select it via soft `nodeSelector` affinity — currently the Cloudflare tunnel deployments, Homepage, Authentik, and parts of the monitoring stack. Affinity is *soft* (`preferredDuringScheduling`), so the Pi can be unplugged at any time without blocking scheduling.

---

## GitOps with Flux

The entire cluster is managed declaratively by [Flux](https://fluxcd.io) — **git is the single source of truth**. Every change flows through a `git push` to this repo; nothing is applied by hand.

- Four `Kustomization`s (`flux-system`, `infrastructure-controllers`, `infrastructure-configs`, `apps`) reconcile every 10 minutes with `prune: true` — deleting a manifest from git deletes it from the cluster.
- A GitHub push webhook triggers an instant reconcile, so the 10-minute interval is mostly a fallback.
- Helm charts are managed as Flux `HelmRelease` resources (helm-controller performs upgrades); chart values are inline in each `*-helmrelease.yaml`.
- Per-deployment values (domain, timezone, LB range, paths) are kept in a single `cluster-settings` ConfigMap and substituted into manifests at reconcile time, so the repo can be forked and redeployed at another site.
- Container image and chart versions are bumped automatically by Renovate; digest and patch updates auto-merge once CI (`kubeconform` + `flux-local`) passes.

`kubectl apply` / `kubectl edit` / `helm upgrade` against a Flux-managed resource is reverted at the next reconciliation — edit the YAML and push instead.

---

## Software

| Layer              | Tool                    |
| ------------------ | ----------------------- |
| Kubernetes distro  | k3s                     |
| GitOps             | Flux                    |
| Ingress controller | Traefik                 |
| Load balancer      | MetalLB                 |
| Remote access      | Cloudflare tunnels      |
| TLS certificates   | cert-manager (Let's Encrypt) |
| Storage engine     | Longhorn                |
| Object storage     | MinIO                   |
| SSO / auth         | Authentik (forward-auth)|
| Secrets management | Bitwarden Secrets Manager + External Secrets Operator |
| Network isolation  | Kubernetes NetworkPolicies |
| Autoscaling        | HPA + VPA               |
| Metrics            | Prometheus + Grafana    |
| Logs               | Loki + Grafana Alloy    |
| Backups            | restic + VolSync        |

The server is only accessed through VPN + SSH.

### How it works

1. **Flux** reconciles the whole cluster from this git repo every 10 minutes (or instantly via webhook).
2. **MetalLB** reserves an IP pool (`192.168.1.55–69`); Traefik is assigned a stable IP from it. AdGuard gets a dedicated LB IP (`192.168.1.60`).
3. **AdGuardHome** runs split-horizon DNS: local services resolve to Traefik's LB IP and are reachable by hostname at `*.local.gabro.ovh`.
4. **TLS**: public services terminate TLS at the Cloudflare edge (cluster-internal ingress is plain HTTP); local services use a wildcard `*.local.gabro.ovh` Let's Encrypt certificate issued by **cert-manager** (Cloudflare DNS-01) and mirrored into every namespace by **Reflector**.
5. **Cloudflare tunnels** expose public services. Each service gets its own dedicated tunnel deployment; tunnel tokens are pulled from Bitwarden Secrets Manager via External Secrets Operator.
6. An aggressive **HPA** is configured on each Cloudflare tunnel deployment (up to 10 replicas, 50% CPU target) since performance scales linearly with pod count.
7. **Stateless offload**: stateless, multi-replica workloads (Cloudflare tunnels, Homepage, Authentik, selected monitoring components) tolerate the Pi's `workload=stateless:NoSchedule` taint, freeing the x86 node for stateful services.
8. **PodDisruptionBudgets** protect critical services (AdGuard, Nextcloud, Cloudflare tunnels) during voluntary disruptions.
9. **NetworkPolicies** enforce a default-deny posture across every namespace, with explicit ingress/egress allow rules per service.
10. **Authentik** sits in front of selected services as a Traefik forward-auth middleware, providing SSO before requests even reach the app.
11. **VPAs** right-size workloads — most run in active mode (`InPlaceOrRecreate`), auto-applying recommended requests/limits; a few stay recommendation-only where active mutation caused churn.
12. **Reloader** rolls workloads automatically when their Secrets or ConfigMaps change.

---

## Repo structure

Flat per-app layout with a `kustomization.yaml` in every leaf — Flux-monorepo style. Each app folder also has a `ks.yaml` (the Flux `Kustomization` that reconciles it).

```
.
├── clusters/homelab/            # Flux entrypoint
│   ├── flux-system/             # Flux components + GitRepository sync
│   ├── cluster-settings.yaml    # per-site values (domain, timezone, paths…)
│   ├── apps.yaml                # apps Kustomization
│   └── infrastructure.yaml      # infrastructure Kustomizations
├── apps/                        # one folder per workload
│   ├── adguard/  alloy/  authentik/  backup/  cert-manager-config/
│   ├── cloudflared/  flux-webhook/  grafana/  headlamp/  homepage/
│   ├── immich/  jellyfin/  lidarr/  longhorn/  loki/  minio/
│   ├── navidrome/  nextcloud/  nut-exporter/  pankha/  prometheus/
│   ├── servarr/  traefik/
│   └── kustomization.yaml
├── infrastructure/
│   ├── controllers/             # cluster-scoped controllers
│   │   ├── cert-manager/        # cert-manager + Cloudflare API token
│   │   ├── coredns/             # coredns-custom ConfigMap
│   │   ├── external-secrets/    # ESO + bitwarden-sdk-server + ClusterSecretStore
│   │   ├── metallb/             # IP pool (192.168.1.55–69)
│   │   ├── reflector/           # Stakater Reflector (mirrors the wildcard TLS Secret)
│   │   ├── reloader/            # Stakater Reloader (rolls pods on Secret/CM change)
│   │   ├── snapshot-controller/ # CSI external-snapshotter
│   │   ├── sources/             # HelmRepository CRs
│   │   ├── volsync/             # VolSync controller + StorageClasses
│   │   └── vpa/                 # VPA controller
│   └── configs/                 # cluster-scoped config (no controllers)
│       ├── namespaces/          # Namespaces + Pod Security Admission labels
│       ├── network-policies/    # per-namespace NetworkPolicies (flat, one file per app)
│       └── upgrade-plans/       # k3s system-upgrade-controller Plans
└── schema/
    ├── cluster-schema-dark.puml # PlantUML source
    ├── cluster-schema-dark.png
    ├── cluster-schema-light.puml
    └── cluster-schema-light.png
```

---

## Services

### 🌐 Public (via Cloudflare tunnel — `*.gabro.ovh`)

| Service                             | Purpose                            |
| ----------------------------------- | ---------------------------------- |
| [Nextcloud](https://nextcloud.com)  | General-purpose cloud storage      |
| [Immich](https://immich.app)        | Personal Google Photos alternative |
| [Jellyfin](https://jellyfin.org)    | Film & TV streaming (SSO-gated)    |
| [Navidrome](https://navidrome.org)  | Music streaming (SSO-gated)        |
| [Authentik](https://goauthentik.io) | Centralized SSO / auth provider    |
| [Grafana](https://grafana.com)      | Monitoring & dashboards            |
| [Homepage](https://gethomepage.dev) | Service dashboard / launcher       |

### 🔒 Private (local only — `*.local.gabro.ovh`)

| Service       | Purpose                                  |
| ------------- | ---------------------------------------- |
| Servarr stack | Automated media acquisition (see below)  |
| AdGuardHome   | Network-level ad blocking + local DNS    |
| Headlamp      | Kubernetes web UI                        |
| MinIO Console | S3 object storage admin UI               |
| Prometheus    | Metrics collection                       |

### 📺 Servarr stack (Jellyfin)

All deployed in the `jellyfin` namespace, pinned to the node with `nodeSelector`, using `hostPath` volumes for config and media.

| App          | Role                    |
| ------------ | ----------------------- |
| Prowlarr     | Indexer manager         |
| Sonarr       | TV show management      |
| Radarr       | Movie management        |
| Seerr        | Request management UI   |
| qBittorrent  | Download client         |
| Dispatcharr  | IPTV / channel manager  |

### 🎵 Servarr stack (Navidrome)

Deployed in the `music` namespace.

| App    | Role                    |
| ------ | ----------------------- |
| Lidarr | Music library manager   |

---

## Security

### Network policies

Every namespace runs with a **default-deny** posture for both ingress and egress. Explicit allow rules are then added per service in `infrastructure/configs/network-policies/`:

- **Ingress** rules typically allow traffic only from `kube-system` (Traefik) and `monitoring` (Prometheus scrape).
- **Egress** rules allow DNS to `kube-system`, in-cluster service discovery, and only the external endpoints each app actually needs (e.g. Cloudflare edge IPs for tunnels, package mirrors, indexer APIs, etc.).

Namespaces covered: `adguard`, `authentik`, `backup`, `cloudflared`, `external-secrets`, `immich`, `jellyfin`, `minio`, `monitoring`, `music`, `nextcloud`, `pankha`.

### Pod Security Admission

Per-namespace PSA labels enforce the `baseline` profile (with `restricted` as a warning) on namespaces with no privileged workloads, and `privileged` on namespaces that genuinely need hostPath / host-namespace access (media stacks, monitoring, backups). New stateless workloads ship a `restricted`-compatible securityContext regardless of namespace.

### Secrets

All sensitive values (database passwords, OAuth client secrets, tunnel tokens, S3 keys, restic encryption keys, etc.) live in **Bitwarden Secrets Manager** (cloud). [External Secrets Operator](https://external-secrets.io) + a `bitwarden-sdk-server` sidecar sync values into Kubernetes Secrets via `ExternalSecret` resources. BW keys follow the convention `<namespace>/<secret-name>/<field>`. The only K8s Secret applied out-of-band is the BWS access token ESO itself uses to talk to Bitwarden.

### TLS certificates

**cert-manager** issues a wildcard `*.local.gabro.ovh` Let's Encrypt certificate via the Cloudflare DNS-01 challenge. The certificate Secret lives in `kube-system` and is mirrored into every app namespace by **Reflector**, so local Ingresses just reference `wildcard-local-tls`. Public services terminate TLS at the Cloudflare edge instead.

### Authentik forward-auth (SSO)

Authentik runs in its own namespace with an outpost reachable at `authentik-server.authentik.svc.cluster.local`. A Traefik `Middleware` of kind `forwardAuth` is defined in the `authentik` namespace (canonical) and mirrored into the `jellyfin` and `music` namespaces to protect Jellyfin and Navidrome. Protected services reference the namespace-local middleware in their `IngressRoute` annotations, so the auth check happens before requests hit the app.

---

## Storage

### Longhorn

[Longhorn](https://longhorn.io) manages distributed persistent volumes and provides the default `StorageClass` used by most workloads. Immich PVCs use Longhorn disk selectors to target specific drives (NVMe for uploads/thumbnails, HDD for originals). A single-replica `longhorn-single` StorageClass is used for VolSync mover cache volumes.

| Drive               | Mount                 | Used for                              |
| ------------------- | --------------------- | ------------------------------------- |
| 1 TB Sabrent NVMe   | `/`                   | OS + fast PVCs                        |
| 500 GB Samsung NVMe | `/mnt/nvme500`        | Additional fast PVCs                  |
| 4 TB HDD            | `/media/gabro/Volume` | Jellyfin / servarr media library      |
| 2 TB HDD            | `/mnt/backups`        | restic repositories (backup target)   |

### MinIO

[MinIO](https://min.io) runs as an in-cluster S3-compatible object store in standalone mode, used as the primary storage backend for Nextcloud. A dedicated `nextcloud` bucket is provisioned with versioning enabled.

---

## Autoscaling

### Horizontal Pod Autoscalers (HPA)

| Target              | Min | Max | Metric    |
| ------------------- | --- | --- | --------- |
| Cloudflared tunnels | 1   | 10  | 50% CPU   |
| Nextcloud           | 1   | 3   | 60% CPU   |
| Immich Server       | 1   | 3   | 70% CPU   |

> The Immich HPA is **CPU-only by design**: pairing a memory-target HPA with a memory-managing VPA pins replicas at max (the VPA shrinks the request, which inflates the HPA's utilization ratio). Jellyfin is intentionally **not** autoscaled — it owns a single SQLite DB on an RWO volume, so it pins to one replica with `strategy: Recreate`.

### Vertical Pod Autoscalers (VPA)

Most VPAs run in **active mode** (`updateMode: InPlaceOrRecreate`) — they auto-apply right-sized requests/limits, in place where the kernel supports it, otherwise by recreating the pod. A few are pinned to recommendation-only (`updateMode: Off`) where active mutation caused churn or fought tightly-tuned manual values — currently Grafana, Loki, MinIO, qBittorrent, and Seerr.

Targets include the servarr stack (Radarr, Sonarr, Prowlarr, qBittorrent, Seerr), Lidarr, Authentik (server / worker / PostgreSQL), Nextcloud (app / PostgreSQL), Immich (server / PostgreSQL), AdGuardHome, Navidrome, MinIO, Jellyfin, Grafana, and Loki.

---

## Monitoring & Logging

### Metrics

Deployed via the `kube-prometheus-stack` Helm chart:

- **Prometheus** with 10-day / 15 GB retention and 20 Gi persistent storage.
- **Grafana** with persistent dashboards (5 Gi) and admin credentials from secrets. Grafana ships as a subchart of `kube-prometheus-stack`; custom dashboards and datasources are managed separately in `apps/grafana/`.
- **Alertmanager**, **kube-state-metrics**, **node-exporter**, and the **Prometheus Operator** — all with resource requests/limits configured.
- `ServiceMonitor`s scrape Traefik, Longhorn, the NUT exporter (UPS metrics), the restic REST server / restic-exporter, and VolSync.

### Logs

- **Loki** (single-binary, filesystem storage, 7-day retention) is the log store.
- **Grafana Alloy** runs as a DaemonSet, tailing `/var/log` on the node and pushing to Loki via the `loki.write` component. It auto-discovers pods on the local node and relabels with namespace, pod, container, and node metadata.
- Loki is wired into Alertmanager via its `rulerConfig`.

### Alerts (PrometheusRule)

| Rule group     | Alerts                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `backup.rules` | `BackupJobFailed`, `BackupCronJobStale`, `BackupCronJobNeverSucceeded`, `CleanupCronJobStale`, `ResticRepoStale`, `ResticRepoCheckFailed`, `ResticRestServerDown`, `ResticExporterDown` |
| `loki.rules`   | `LokiDown`, `LokiNoNewLogs`                                                                                                     |

Alerts are delivered to Telegram via Alertmanager.

---

## Backups

All backups are restic-based and converge on an **in-cluster restic REST server** — a Deployment in the `backup` namespace running `restic/rest-server` in `--append-only` mode, storing repositories on the 2 TB HDD at `/mnt/backups/restic`. Append-only mode means backup jobs can write but not delete; only the prune job (with separate admin credentials) can.

| Job                  | Type                       | Schedule          | Method                                                          |
| -------------------- | -------------------------- | ----------------- | --------------------------------------------------------------- |
| `immich-db-backup`   | `pg_dump` CronJob          | every 3 days      | dump → gzip → `restic backup` to the REST server                |
| `nextcloud-db-backup`| `pg_dump` CronJob          | every 3 days      | dump → gzip → `restic backup` to the REST server                |
| `authentik-db-backup`| `pg_dump` CronJob          | every 3 days      | dump → gzip → `restic backup` to the REST server                |
| `immich-library`     | VolSync `ReplicationSource`| every 3 days      | `restic`, `copyMethod: Direct` (mounts the live PVC)            |
| `minio`              | VolSync `ReplicationSource`| every 3 days      | `restic`, `copyMethod: Direct` — backs up Nextcloud's S3 data   |
| `restic-prune`       | CronJob                    | weekly (Sun 06:00)| `forget --prune` + integrity `check` across all repositories    |

- The database dumps run as non-root jobs in their app's own namespace, waiting for PostgreSQL before dumping to an `emptyDir`.
- The bulk-data PVCs (Immich photo library, MinIO object store) are handled by **VolSync** using `copyMethod: Direct` — no full-size clone PVC, the mover mounts the live volume and is pinned to the source pod's node.
- Retention is 7 daily / 4 weekly / 12 monthly snapshots per repository.
- A `restic-exporter` (one per repository) feeds snapshot freshness and integrity-check metrics to Prometheus; failed, stale, or corrupt repositories trigger alerts.
- All jobs have `activeDeadlineSeconds` set to prevent hung runs and `concurrencyPolicy: Forbid` to avoid overlap.

### Weekly cluster cleanup

Two `CronJob`s in `kube-system` run Sundays:

- `k8s-resource-cleanup` — sweeps stale `Succeeded`/`Failed` pods and orphaned ReplicaSets cluster-wide, using a dedicated `ServiceAccount` + `ClusterRole` scoped only to those resources.
- `host-cleanup` — prunes unused container images, vacuums journal logs older than 7 days, and clears the apt cache on the node.

---

## Nextcloud

Nextcloud is the most complex deployment in the cluster:

- **Helm chart** for the main Nextcloud pod with PostgreSQL and Redis.
- **S3 primary storage** via MinIO (`objectstore.config.php` configured in Helm values).
- **Dedicated CronJob** (`nextcloud-cron`) running `cron.php` every 5 minutes for background tasks.
- **HSTS middleware** via Traefik (`stsSeconds: 15552000`, preload enabled).
- **PodDisruptionBudget** ensuring at least 1 pod is always available.
- **HPA** scaling up to 3 replicas on 60% CPU utilization.

> The Nextcloud AppAPI / Docker Socket Proxy was deliberately removed: it required a privileged container with access to the host's container socket — a Nextcloud RCE could have escalated straight to root on the node. It is not reintroduced unless ExApps become genuinely necessary.
