# Flux Rollback Runbook

Recovery procedures for when Flux misbehaves. Read top to bottom on first
read; later, jump to the scenario that matches.

## Pre-flight: take a snapshot before bootstrapping

```bash
kubectl get all,configmap,secret,ingress,ingressroute,pdb,vpa,hpa,externalsecret,clustersecretstore -A > /tmp/cluster-snapshot-pre-flux.txt
git log -1 --format='%H %s' > /tmp/git-state-pre-flux.txt
```

Keep both files. The first reconcile after `flux bootstrap` shouldn't change
anything — if it does, `diff` against the snapshot to find what drifted.

## Quick reference

```bash
# What is Flux doing right now
flux get kustomization -A
flux get sources git -A
flux get helmrelease -A         # only after step 4 of adoption

# Pause everything (Flux stops reconciling but stays installed)
flux suspend kustomization apps -n flux-system
flux suspend kustomization infrastructure-controllers -n flux-system
flux suspend kustomization infrastructure-configs -n flux-system

# Resume
flux resume kustomization apps -n flux-system

# Force a reconcile now (don't wait for the interval)
flux reconcile kustomization apps -n flux-system --with-source

# See what would change (dry-run)
flux diff kustomization apps --path ./apps
```

## Scenario 1 — First reconcile after bootstrap broke something

Flux just took ownership of a stack of resources and one or more is now
crashed or unhealthy.

1. **Suspend all three Kustomizations immediately:**
   ```bash
   flux suspend kustomization apps -n flux-system
   flux suspend kustomization infrastructure-controllers -n flux-system
   flux suspend kustomization infrastructure-configs -n flux-system
   ```
   At this point Flux is alive but does nothing. The cluster is yours again.
2. **Find what broke:**
   ```bash
   flux get kustomization -A
   kubectl describe kustomization <name> -n flux-system | tail -40
   ```
3. **Fix it** — either edit the manifest in git (preferred, then resume) or
   `kubectl apply` a hotfix directly (and remember to mirror back to git
   before resuming, or Flux will revert it).
4. **Resume in dependency order:**
   ```bash
   flux resume kustomization infrastructure-configs -n flux-system
   flux resume kustomization infrastructure-controllers -n flux-system
   flux resume kustomization apps -n flux-system
   ```

## Scenario 2 — One specific Kustomization is in `False` Ready state

```bash
flux get kustomization -A          # find the failing one
kubectl describe kustomization <name> -n flux-system | tail -40
```

Common causes and fixes:

- **SSA field-manager conflict** — error contains `conflicts with "helm"` or
  `conflicts with "<release-name>"`. The resource was previously owned by
  Helm v3/v4 directly. Either temporarily `kubectl patch` the field-manager
  reference, or annotate the resource with
  `kustomize.toolkit.fluxcd.io/ssa: ignore` to skip just that field. Long-term
  fix: convert the chart to a `HelmRelease` (Flux adoption step 4).
- **Resource not found** — a referenced ConfigMap/Secret doesn't exist
  yet. Apply it manually or add it to the same Kustomization. Most often
  hits ExternalSecrets that depend on `external-secrets/bitwarden-access-token`.
- **Validation error** — manifest is invalid. `flux diff kustomization
  <name>` to see what would apply, fix the YAML in git.

## Scenario 3 — Flux pruned something it shouldn't have

`prune: true` on every Kustomization means anything removed from git gets
deleted from the cluster. If a resource you needed disappeared:

1. **Suspend the Kustomization first** so it doesn't re-prune:
   ```bash
   flux suspend kustomization <name> -n flux-system
   ```
2. **Restore from git history:**
   ```bash
   git log --diff-filter=D --name-only -- 'apps/**'
   git show <commit>^:apps/<path>/<file>.yaml | kubectl apply -f -
   ```
3. **Decide what you actually want** — re-add the file to git and `flux
   resume`, OR keep it manually-applied and leave the Kustomization
   suspended for that path.

## Scenario 4 — A bad commit landed on `main` and Flux applied it

```bash
git revert <bad-sha>
git push
flux reconcile source git flux-system -n flux-system
```

Flux pulls the revert and re-applies. If reconcile is slow and you need it
now:

```bash
flux reconcile kustomization apps -n flux-system --with-source
```

## Scenario 5 — Full back-out (uninstall Flux entirely)

You've decided Flux isn't for you. Cluster goes back to manual `kubectl
apply`.

1. **Suspend everything** (so nothing reconciles during teardown):
   ```bash
   flux suspend kustomization --all -n flux-system
   ```
2. **Uninstall Flux** (this removes the controllers and the CRs they own,
   but **leaves your workloads running** because Flux Kustomizations don't
   own the underlying resources):
   ```bash
   flux uninstall --silent
   ```
3. **Remove the cluster definition from git:**
   ```bash
   git rm -r clusters/homelab/flux-system/
   git commit -m "Remove Flux"
   git push
   ```
4. **You're back to the pre-Flux state.** The kustomize layout still works
   with `kubectl apply -k`.

## Scenario 6 — Flux can't talk to GitHub

```bash
flux get sources git -A             # check the GitRepository status
kubectl logs -n flux-system deployment/source-controller --tail=50
```

Most often this is the PAT expiring, the deploy key getting rotated, or
egress NetworkPolicy blocking `api.github.com`. Check
`infrastructure/configs/network-policies/` for an `allow-flux-egress` rule —
if it's missing, the source-controller pod needs to be able to reach
`140.82.0.0/16` (GitHub) on 443.

## When in doubt

`flux suspend kustomization --all -n flux-system` is the panic button. It
freezes Flux without uninstalling anything. The cluster keeps running with
whatever state it had at the moment of suspension. Take a breath, then
investigate.
