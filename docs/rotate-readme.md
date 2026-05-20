# Rotating Secrets

How to rotate every secret in this cluster. Read this before doing a rotation pass — some entries have order-of-operations traps that will lock you out if you skip them.

---

## 0. The two-line summary

- For most secrets: **update the value in Bitwarden first**, then run the matching `task rotate-*` command. The task force-syncs the ExternalSecret and rolls consumer Deployments.
- The exceptions (Postgres, MinIO root, restic repo passwords, the BWS access token itself) need a specific *runtime-side* change before or after the BW update. Each is documented below.

## 1. Tasks at a glance

```
task secrets-list                                     # status of every ExternalSecret
task rotate-bws ns=X name=Y [deploy=Z]                # generic: force-sync + optional restart
task rotate-tunnel svc=jellyfin                       # any of 7 Cloudflare tunnels
task rotate-cloudflare-api                            # cert-manager's CF API token
task rotate-webhook-hmac                              # Flux GitHub webhook HMAC
task rotate-grafana-admin                             # Grafana admin password
task rotate-postgres app=nextcloud                    # one of nextcloud, authentik, immich, pankha
```

What each task does internally is in `Taskfile.yaml`. They all expect BW to already hold the new value when invoked.

---

## 2. The full inventory

Every secret in the cluster, by rotation category. The "BW path" column is the key path used in Bitwarden Secrets Manager — convention is `<namespace>/<secret-name>/<field>`.

### 2.1 Simple BWS-only (use `task rotate-bws` or the dedicated task)

These live entirely in Bitwarden. Procedure: rotate in BW UI → run task → app picks up the new value on restart.

| Secret | BW path | Rotation task | Notes |
|---|---|---|---|
| Grafana admin password | `monitoring/grafana-admin-credentials/admin-password` | `rotate-grafana-admin` | Old browser sessions remain valid until cookie expiry. |
| Authentik secret-key | `authentik/authentik-credentials/secret-key` | `rotate-bws ns=authentik name=authentik-credentials deploy=authentik-server` | Invalidates every Authentik session and signed token; users get logged out everywhere. Roll `authentik-worker` too. |
| Immich JWT secret | `immich/immich-secrets/JWT_SECRET` | `rotate-bws ns=immich name=immich-secrets deploy=immich-server` | Invalidates mobile/desktop app sessions — users have to re-login. |
| Nextcloud secret key | `nextcloud/nextcloud-secrets/secret` | `rotate-bws ns=nextcloud name=nextcloud-secrets deploy=nextcloud` | Invalidates encrypted previews/cookies. |
| Pankha JWT + session keys | `pankha/pankha-secrets/JWT_SECRET`, `.../SESSION_SECRET` | `rotate-bws ns=pankha name=pankha-secrets deploy=pankha-app` | Invalidates dashboard sessions. |
| Alertmanager Telegram bot token | `monitoring/alertmanager-telegram/token` | `rotate-bws ns=monitoring name=alertmanager-telegram deploy=alertmanager-monitoring-kube-prometheus-alertmanager` | Generate new in @BotFather first; old keeps working until you `/revoke`. |
| Grafana ↔ Authentik OAuth client secret | `monitoring/grafana-authentik-oauth/client-secret` | `rotate-bws ns=monitoring name=grafana-authentik-oauth deploy=monitoring-grafana` | Rotate in Authentik UI (Application → Provider → "Generate new") AND BW in lockstep. Brief SSO-login outage. |

### 2.2 Cloudflare tunnel tokens (`task rotate-tunnel svc=<name>`)

Seven tunnels. Each is generated in the Cloudflare dashboard for that specific tunnel (Zero Trust → Networks → Tunnels → pick tunnel → Refresh token), then stored in BW.

| Tunnel | BW path |
|---|---|
| jellyfin | `cloudflared/jellyfin-tunnel-token/token` |
| nextcloud | `cloudflared/nextcloud-tunnel-token/token` |
| immich | `cloudflared/immich-tunnel-token/token` |
| authentik | `cloudflared/authentik-tunnel-token/token` |
| navidrome | `cloudflared/navidrome-tunnel-token/token` |
| adguard | `cloudflared/adguard-tunnel-token/token` |
| monitoring | `cloudflared/monitoring-tunnel-token/token` |

Run after BW is updated:
```
task rotate-tunnel svc=jellyfin
```

The task force-syncs the ExternalSecret and rolls `deploy/cloudflared-<svc>`. Brief downtime (~10s) for that public hostname during the rollout.

Reminder: `flux-webhook.gabro.ovh` and `authentik.gabro.ovh` ride on the **same** tunnel (the one whose token is at `cloudflared/authentik-tunnel-token/token`). Rotating it affects both hostnames at once.

### 2.3 Other external-provider tokens

| Secret | Where to generate | BW path | Rotation task |
|---|---|---|---|
| Cloudflare API token (cert-manager DNS-01) | CF dash → "My Profile" → API Tokens. Permissions: Zone:DNS:Edit on `gabro.ovh`. | `cert-manager/cloudflare-api-token/api-token` | `rotate-cloudflare-api` |
| GitHub webhook HMAC | GitHub repo → Settings → Webhooks → edit `flux-webhook.gabro.ovh` → regenerate secret. | `flux-system/github-webhook-token/token` | `rotate-webhook-hmac` |

### 2.4 Postgres passwords (`task rotate-postgres app=<name>`)

Four Postgres-backed apps. The task handles the order-of-operations automatically: reads old password, force-syncs ES, ALTER USERs with the new value, rolls consumers.

| App | BW path | Postgres pod | Consumer Deployments |
|---|---|---|---|
| nextcloud | `nextcloud/nextcloud-db/db-password` | `nextcloud-postgresql-0` | `nextcloud` |
| authentik | `authentik/authentik-credentials/postgresql-password` | `authentik-postgresql-0` | `authentik-server`, `authentik-worker` |
| immich | `immich/immich-secrets/POSTGRES_PASSWORD` (also `DB_PASSWORD` — keep both equal) | `immich-postgresql-0` | `immich-server`, `immich-machine-learning` |
| pankha | `pankha/pankha-secrets/POSTGRES_PASSWORD` | (pankha-postgres deploy) | `pankha-app` |

Run:
```
task rotate-postgres app=nextcloud
```

If the task errors with "Secret value did not change after force-sync," you forgot to update BW — fix that, then re-run.

### 2.5 Nextcloud Redis password

Same shape as Postgres but no ALTER USER — Redis takes the password from env. The Redis is internal to the chart, the password lives in the chart's own Secret and is referenced by both server and clients. Procedure:

1. Update `nextcloud/nextcloud-redis/password` in BW.
2. `task rotate-bws ns=nextcloud name=nextcloud-redis`
3. `kubectl -n nextcloud rollout restart deploy/nextcloud` (clients) **and** `kubectl -n nextcloud rollout restart statefulset/nextcloud-redis-master statefulset/nextcloud-redis-replicas` (server).
4. Brief outage while clients reconnect.

---

## 3. The harder ones (no task, manual procedure)

### 3.1 MinIO root credentials

Used by Nextcloud as primary S3 storage, and by VolSync to back up the MinIO PVC. Rotating root means re-coordinating MinIO + Nextcloud + the volsync minio replicationsource.

```bash
# 1. Generate a new MinIO root user/password locally — pick any strong value.
NEW_USER=admin
NEW_PW=$(openssl rand -base64 32)

# 2. Update BW: minio/minio-root-credentials/root-user, .../root-password

# 3. Force-sync; this updates the in-cluster Secret BUT NOT the running MinIO.
task sync-es ns=minio name=minio-root-credentials

# 4. Restart MinIO to read the new env vars on next start.
#    Bitnami MinIO chart reads MINIO_ROOT_USER/MINIO_ROOT_PASSWORD only at boot.
kubectl -n minio rollout restart deploy/minio
kubectl -n minio rollout status deploy/minio

# 5. Nextcloud uses the MinIO root creds for primary S3 — verify Nextcloud
#    still mounts the bucket:
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- \
  php /var/www/html/occ files:scan --all 2>&1 | head -5
```

If MinIO refuses to start with the new password (rare), check the chart's `auth.rootUser`/`auth.rootPassword` settings — they reference the Secret via `existingSecret`. Roll back by restoring the old value to BW and re-syncing.

### 3.2 MinIO Nextcloud user

A separate non-root MinIO user used by Nextcloud's primary S3 backend (the `existingSecret: nextcloud-s3` reference in `nextcloud-helmrelease.yaml`).

```bash
# 1. Pick a new password.
NEW_PW=$(openssl rand -base64 32)

# 2. As root, change the user's password inside MinIO:
kubectl -n minio exec deploy/minio -- \
  mc admin user enable local nextcloud-user
kubectl -n minio exec deploy/minio -- \
  mc admin user add local nextcloud-user "$NEW_PW"  # overwrites password

# 3. Update BW: minio/minio-nextcloud-user/access-key (unchanged), .../secret-key (= NEW_PW)
#    AND nextcloud/nextcloud-s3/secret-key to the SAME value.

# 4. Force-sync both, restart nextcloud:
task sync-es ns=minio name=minio-nextcloud-user
task sync-es ns=nextcloud name=nextcloud-s3
kubectl -n nextcloud rollout restart deploy/nextcloud
```

### 3.3 restic repository passwords

**WARNING:** A restic repo password is the master key for that repo's encryption. You can't "change" it — you can only `key add` a new key and `key remove` the old one. Doing it wrong locks you out of the repo permanently. Backups remain readable as long as ANY key is valid.

Five repos, each independent: `immich-files`, `immich-db`, `nextcloud-db`, `nextcloud-minio`, `authentik-db`.

```bash
# Example: rotate the nextcloud-db repo password.
REPO=nextcloud-db
NS=nextcloud  # namespace whose restic-creds reference this repo
OLD_PW=$(kubectl -n $NS get secret restic-creds -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)
NEW_PW=$(openssl rand -base64 32)

# 1. Add the new key to the repo, authenticating with OLD_PW:
kubectl -n $NS run --rm -i restic-rotate --image=restic/restic --restart=Never \
  --env="RESTIC_PASSWORD=$OLD_PW" \
  --env="RESTIC_REPOSITORY=rest:http://restic-rest-server.backup.svc:8000/$REPO" \
  --command -- sh -c "echo '$NEW_PW' | restic key add --host rotate --user rotate"

# 2. Verify the new key works (list snapshots with new password):
kubectl -n $NS run --rm -i restic-verify --image=restic/restic --restart=Never \
  --env="RESTIC_PASSWORD=$NEW_PW" \
  --env="RESTIC_REPOSITORY=rest:http://restic-rest-server.backup.svc:8000/$REPO" \
  --command -- restic snapshots --last

# 3. Update BW: <ns>/restic-creds/RESTIC_PASSWORD = NEW_PW

# 4. Force-sync the ExternalSecret:
task sync-es ns=$NS name=restic-creds

# 5. ALSO update the matching volsync entry if this repo is used by VolSync:
#    - immich-files → immich/volsync-restic-immich-library
#    - nextcloud-minio → minio/volsync-restic-minio
#    Update BW under volsync-restic-*/RESTIC_PASSWORD with the same NEW_PW, then sync.

# 6. Verify the next backup job succeeds (CronJob 'nextcloud-db-backup' runs every 3 days;
#    trigger an immediate run to test):
kubectl -n $NS create job --from=cronjob/nextcloud-db-backup nextcloud-db-backup-rotate-test
kubectl -n $NS logs job/nextcloud-db-backup-rotate-test --follow

# 7. Once the next real backup succeeds, remove the old key:
OLD_KEY_ID=$(kubectl -n $NS run --rm -i restic-list --image=restic/restic --restart=Never \
  --env="RESTIC_PASSWORD=$NEW_PW" \
  --env="RESTIC_REPOSITORY=rest:http://restic-rest-server.backup.svc:8000/$REPO" \
  --command -- restic key list | awk '/^ /{print $1; exit}')
kubectl -n $NS run --rm -i restic-remove --image=restic/restic --restart=Never \
  --env="RESTIC_PASSWORD=$NEW_PW" \
  --env="RESTIC_REPOSITORY=rest:http://restic-rest-server.backup.svc:8000/$REPO" \
  --command -- restic key remove "$OLD_KEY_ID"
```

**Do not skip step 2** — if the new key doesn't actually work, you'll discover this only when you try to restore from a future backup. Verify it works *before* you trust it.

### 3.4 restic REST server htpasswd credentials

Used by every backup job to authenticate to `restic-rest-server.backup.svc:8000`. There are two tiers: writer (used by all backup jobs, `--append-only` enforced) and admin (used only by `restic-prune` for forget/check).

The htpasswd file is regenerated by the rest-server pod's `build-htpasswd` initContainer on every start, from whatever values are in the `restic-rest-server-creds` Secret. So:

```bash
# 1. Pick new writer and/or admin passwords.
#    Update BW: backup/restic-rest-server-creds/writer-password
#                backup/restic-rest-server-creds/admin-password
#                backup/restic-admin-creds/password (same as admin-password — keep in sync)

# 2. Force-sync both:
task sync-es ns=backup name=restic-rest-server-creds
task sync-es ns=backup name=restic-admin-creds

# 3. ALSO update each consumer's restic-creds in lockstep — every namespace that
#    holds an ExternalSecret containing the writer creds. The relevant fields:
#      authentik/restic-creds/RESTIC_REST_USERNAME + RESTIC_REST_PASSWORD
#      immich/restic-creds/RESTIC_REST_USERNAME + RESTIC_REST_PASSWORD
#      nextcloud/restic-creds/RESTIC_REST_USERNAME + RESTIC_REST_PASSWORD
#      immich/volsync-restic-immich-library/... (matching values)
#      minio/volsync-restic-minio/... (matching values)
#    Then:
for ns in authentik immich nextcloud; do
  task sync-es ns=$ns name=restic-creds
done
task sync-es ns=immich name=volsync-restic-immich-library
task sync-es ns=minio name=volsync-restic-minio

# 4. Restart the rest-server to regenerate the htpasswd file. Until you do this,
#    OLD creds keep working — which is actually fine for the rollout, the backup
#    jobs continue to succeed until step 4 completes.
kubectl -n backup rollout restart deploy/restic-rest-server
kubectl -n backup rollout status deploy/restic-rest-server

# 5. Verify a backup job runs successfully on the new creds (trigger one):
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-backup nextcloud-db-backup-htpasswd-test
kubectl -n nextcloud logs job/nextcloud-db-backup-htpasswd-test --follow
```

If step 5 fails, revert BW and force-sync — the old creds are still in the consumer Secrets until you do this.

---

## 4. The bootstrap exception: BWSM access token

This is the only secret that cannot rotate via Flux — ESO needs it to talk to Bitwarden in the first place. The Secret lives at `external-secrets/bitwarden-access-token` and is applied out-of-band per CLAUDE.md.

Procedure is documented separately — see the rotation runbook I gave you in chat. The short version:

1. Generate a NEW token in BW → Machine accounts → Access tokens. **Do not revoke the old token yet.**
2. Backup the current Secret: `kubectl -n external-secrets get secret bitwarden-access-token -o yaml > ~/bw-token-old.yaml.bak`.
3. `kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token="$NEW" --dry-run=client -o yaml | kubectl apply -f -`
4. `kubectl -n external-secrets rollout restart deploy/external-secrets`
5. Verify: `kubectl get clustersecretstore bitwarden-secretsmanager -o jsonpath='{.status.conditions}'` shows Ready=True. Force-sync any ExternalSecret and confirm it syncs.
6. Revoke the old token in BW UI. Delete the backup file.

If step 5 fails: `kubectl apply -f ~/bw-token-old.yaml.bak` rolls you back instantly because the old token is still valid in BW.

---

## 5. Annual rotation pass

Suggested order (least to most disruptive). Each step is independent; you can do them across multiple sessions.

1. **Tunnel tokens** (7×) — `task rotate-tunnel svc=<name>` for each. Quick.
2. **External-provider tokens** — `task rotate-cloudflare-api`, `task rotate-webhook-hmac`. Quick.
3. **App admin credentials** — `task rotate-grafana-admin`. Quick.
4. **Postgres passwords** (4×) — `task rotate-postgres app=<name>` for each. ~30s app downtime each.
5. **Redis password** — manual procedure (§2.5). ~30s outage.
6. **MinIO root** + **MinIO nextcloud-user** — §3.1, §3.2. ~1m Nextcloud outage.
7. **App signing keys** — Authentik secret-key, Immich JWT, Nextcloud secret, Pankha JWT/session. Each forces a re-login on every device for that app. Do these last.
8. **restic REST server htpasswd** — §3.4. Lockstep update across 5 consumer namespaces. Test a backup before moving on.
9. **restic repo passwords** (5×) — §3.3. The riskiest; verify each one works before removing the old key.
10. **BWS access token** — §4. Do this only after everything above is healthy and you've confirmed ESO is syncing all ExternalSecrets.

Allow ~2 hours for a full pass.

---

## 6. Lockout escape hatches

If you've locked yourself out of something:

- **Bitwarden Secrets Manager broken / ESO can't sync**: every ExternalSecret stops refreshing, but the existing Kubernetes Secrets remain valid until you manually delete them. So the cluster keeps running on old creds. Fix the BWS token (§4) and force-sync everything.
- **Postgres password mismatch (app can't connect after rotation)**: connect to postgres as superuser via `kubectl -n <ns> exec -it <pg-pod>-0 -- psql -U postgres` and re-set the password to match BW: `ALTER USER <user> WITH PASSWORD '<value from BW>';`.
- **Authentik admin locked out**: there's a fallback admin password in `authentik/authentik-credentials/admin-password` if configured. Otherwise reset via worker: `kubectl -n authentik exec deploy/authentik-worker -- ak create_admin_group`.
- **Nextcloud admin locked out**: `kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ user:resetpassword gabro` (interactive).
- **Cloudflare tunnel broken**: any tunnel with bad credentials shows offline in the CF dashboard. Generate a fresh token, update BW, run the task. If multiple tunnels fail at once, suspect the tunnel-routing assumption ([[project_authentik_bypasses_traefik]]) — verify the originService in CF dashboard.
- **restic repo locked out (lost the password)**: the only recovery is the latest valid `restic key list` output you kept. If you didn't keep one, the repo's snapshots are unrecoverable. Restic does not have a backdoor.

---

## 7. What this doc deliberately doesn't cover

- **TLS certificates** — issued by cert-manager via Let's Encrypt DNS-01, auto-renewed. No rotation needed manually.
- **Kubernetes ServiceAccount tokens** — auto-rotated by the kubelet. Don't touch.
- **k3s node tokens** — only relevant when adding a new node; see Rancher docs.
- **Bitwarden personal vault passwords** — that's between you and your password manager. Not in scope here.
