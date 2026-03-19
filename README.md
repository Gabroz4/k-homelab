
# Gabro's Homelab 🖥️

> A k3s cluster with production-grade infrastructure — built to learn, experiment, and run self-hosted services.

![k3s](https://img.shields.io/badge/k3s-lightweight_k8s-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-ingress-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-tunnels-F38020?style=flat-square&logo=cloudflare&logoColor=white)
![Longhorn](https://img.shields.io/badge/Longhorn-storage-5F259F?style=flat-square)
![Helm](https://img.shields.io/badge/Helm-package_manager-0F1689?style=flat-square&logo=helm&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-monitoring-E6522C?style=flat-square&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-dashboards-F46800?style=flat-square&logo=grafana&logoColor=white)
![MetalLB](https://img.shields.io/badge/MetalLB-load_balancer-4A90D9?style=flat-square)
![MinIO](https://img.shields.io/badge/MinIO-object_storage-C72E49?style=flat-square&logo=minio&logoColor=white)
![Authentik](https://img.shields.io/badge/Authentik-SSO-FD4B2D?style=flat-square)
![AdGuard](https://img.shields.io/badge/AdGuard-DNS-68BC71?style=flat-square&logo=adguard&logoColor=white)
![Nextcloud](https://img.shields.io/badge/Nextcloud-self_hosted_cloud-0082C9?style=flat-square&logo=nextcloud&logoColor=white)
![Jellyfin](https://img.shields.io/badge/Jellyfin-media_server-00A4DC?style=flat-square&logo=jellyfin&logoColor=white)
![Immich](https://img.shields.io/badge/Immich-photo_backup-4250AF?style=flat-square)

---

## Hardware

Almost all hardware was recycled from previous upgrades, found laying around, or gifted by friends. The only purchases were the micro-ATX parts (mobo, case, PSU — cheapest available, student budget).

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

---

## Software

| Layer              | Tool               |
| ------------------ | ------------------ |
| Kubernetes distro  | k3s                |
| Ingress controller | Traefik            |
| Load balancer      | MetalLB            |
| Remote access      | Cloudflare tunnels |
| Storage            | Longhorn           |

All configuration is deployed with standard `kubectl` except Nextcloud which uses Helm. No patches are applied to maximize reproducibility — pods are configured as-is in the YAML files.

### How it works

1. MetalLB reserves an IP pool; Traefik is assigned a stable IP from it.
2. AdGuardHome is configured with DNS rewrites so browsers can reach local services by hostname via Traefik.
3. Publicly exposed services point Traefik's pod IP as the Cloudflare target.
4. All internet-facing services go through a Cloudflare tunnel pod. Since performance scales linearly with pod count, an aggressive HPA is configured on the tunnel deployment.

---

## Services

### 🌐 Public (via Cloudflare tunnel)

| Service                             | Purpose                            |     |
| ----------------------------------- | ---------------------------------- | --- |
| [Jellyfin](https://jellyfin.org)    | Film streaming                     |     |
| [Nextcloud](https://nextcloud.com)  | General-purpose cloud storage      |     |
| [Immich](https://immich.app)        | Personal Google Photos alternative |     |
| [Navidrome](https://navidrome.org)  | Music streaming                    |     |
| [Authentik](https://goauthentik.io) | Centralized SSO / auth provider    |     |
| [Grafana](https://grafana.com)      | Monitoring & dashboards            |     |
| [Headlamp](https://headlamp.dev)    | Kubernetes UI                      |     |

### 🔒 Private (local only)

| Service     | Purpose                                     |
| ----------- | ------------------------------------------- |
| *arr stack  | Automated media acquisition for Jellyfin    |
| AdGuardHome | Network-level filtering + local DNS         |
| Peanut      | UPS monitoring*(running on Docker for now)* |

---
## Storage

### Longhorn
[Longhorn](https://longhorn.io) manages distributed persistent volumes across the cluster and provides the default `StorageClass` used by most workloads.

| Drive               | Mount          | Used for                   |
| ------------------- | -------------- | -------------------------- |
| 1 TB Sabrent NVMe   | `/`            | OS + fast PVCs             |
| 500 GB Samsung NVMe | `/mnt/nvme500` | Additional fast PVCs       |
| 4 TB HDD            | `/mnt/media`   | Jellyfin media library     |
| 2 TB HDD            | `/mnt/backups` | Backup target for all jobs |

### MinIO
[MinIO](https://min.io) runs as an in-cluster S3-compatible object store, used as the primary storage backend for Nextcloud. Reachable inside the cluster at `http://minio.minio.svc.cluster.local:9000`.

---

## Backups

All backup jobs are `CronJob` resources that write to the 2 TB HDD mounted at `/mnt/backups`.

- Jobs are staggered 20 min apart to avoid I/O contention on the backup drive.
- `immich-files-backup` uses [restic](https://restic.net) for deduplication and pruning. The repo is initialised automatically on first run.
- Nextcloud DB and Immich DB use `pg_dump` piped directly to gzip. Old dumps older than 7 days are pruned.
