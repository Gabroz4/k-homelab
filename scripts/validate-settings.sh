#!/usr/bin/env bash
#
# validate-settings.sh — guard the cluster-settings templating contract.
#
# Three checks, all driven off clusters/homelab/cluster-settings.yaml so the
# script needs no edits when a variable is added:
#
#   1. undefined  Every ${VAR} referenced in a Flux-substituted manifest is a
#                 key in cluster-settings. kustomize-controller runs without
#                 --strict-substitutions, so an unknown ${VAR} renders as an
#                 empty string instead of failing: an empty loadBalancerIP
#                 hands the service back to the MetalLB pool, an empty
#                 nodeSelector makes its workload unschedulable.
#
#   2. literals   No manifest hardcodes a value that cluster-settings already
#                 defines. Catches a new manifest that copy-pastes 192.168.0.9
#                 instead of referencing ${PRIMARY_NODE_IP}. Matching is
#                 whole-token: without that, the node name 'homelab' matches
#                 every identity string that merely embeds it
#                 (pankha-agent-homelab, k-homelab, homelab-power-temps).
#                 Deliberate literals are allowlisted, with a reason, in
#                 scripts/validate-settings.ignore.
#
#   3. drift      Every key in the git ConfigMap also exists in the live one.
#                 A key that is only in git renders empty on the next
#                 reconcile — apply the ConfigMap before pushing. Skipped when
#                 no cluster is reachable, so this stays CI-safe.
#
# Exit 1 on check 1 or 2. Check 3 warns by default, fails under --strict.
#
# Grafana dashboards escape their own templating as $${var}; those are stripped
# before scanning so Grafana variables are not mistaken for Flux ones.

set -euo pipefail

SETTINGS="clusters/homelab/cluster-settings.yaml"
IGNORE="scripts/validate-settings.ignore"
SCAN_PATHS=(apps infrastructure)
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

cd "$(dirname "$0")/.."
[ -f "$SETTINGS" ] || { echo "cannot find $SETTINGS"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# key <TAB> value <TAB> regex-escaped value
python3 -c "
import yaml, re
for k, v in yaml.safe_load(open('$SETTINGS'))['data'].items():
    print(k, v, re.escape(str(v)), sep='\t')
" > "$TMP/vars"

grep -vE '^\s*(#|$)' "$IGNORE" 2>/dev/null > "$TMP/ignore" || : > "$TMP/ignore"

 mapfile -t FILES < <(git ls-files --cached --others --exclude-standard "${SCAN_PATHS[@]}" | grep -E '\.ya?ml$')

# One awk pass over every manifest handles checks 1 and 2.
awk -v varfile="$TMP/vars" -v ignfile="$TMP/ignore" '
BEGIN {
  while ((getline l < varfile) > 0) { n=split(l,a,"\t"); if(n>=3){ nk++; key[nk]=a[1]; val[nk]=a[2]; esc[nk]=a[3]; iskey[a[1]]=1;
    any = any (any ? "|" : "") a[3] } }
  any = "(" any ")"
  while ((getline l < ignfile) > 0) { sub(/[ \t]+$/,"",l); if(l!="") ign[l]=1 }
}
{
  where = FILENAME ":" FNR

  # --- check 1: ${VAR} that cluster-settings does not define ---------------
  s = $0
  gsub(/\$\$\{[^}]*\}/, "", s)              # drop Grafana-escaped $${var}
  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    v = substr(s, RSTART+2, RLENGTH-3)
    if (!(v in iskey)) print "UNDEF\t" where "\t" v
    s = substr(s, RSTART+RLENGTH)
  }

  # --- check 2: literal that a variable already covers ---------------------
  if (where in ign) next
  c = $0
  gsub(/\$\{[^}]*\}/, "", c)                # drop already-templated refs
  if (c !~ any) next                        # cheap prefilter: most lines hold no value at all
  for (i = 1; i <= nk; i++)
    if (c ~ ("(^|[^A-Za-z0-9_.-])" esc[i] "([^A-Za-z0-9_-]|$)"))
      print "LIT\t" where "\t" key[i] "\t" val[i]
}
' "${FILES[@]}" > "$TMP/findings"

rc=0

echo "==> checking for undefined \${VAR} references"
if grep -q '^UNDEF' "$TMP/findings"; then
  awk -F'\t' '$1=="UNDEF" { print "  " $2 "  ${" $3 "} is not a cluster-settings key" }' "$TMP/findings"
  rc=1
else
  echo "    ok"
fi

echo "==> checking for literals that cluster-settings already defines"
if grep -q '^LIT' "$TMP/findings"; then
  awk -F'\t' '$1=="LIT" { print "  " $2 "  hardcodes \x27" $4 "\x27 — use ${" $3 "} (or allowlist in validate-settings.ignore)" }' "$TMP/findings"
  rc=1
else
  echo "    ok"
fi

echo "==> checking git ConfigMap against the live one"
if ! kubectl -n flux-system get cm cluster-settings -o json >"$TMP/live" 2>/dev/null; then
  echo "    skipped (no cluster reachable)"
else
  missing=$(python3 -c "
import json
live = json.load(open('$TMP/live'))['data']
keys = [l.split('\t')[0] for l in open('$TMP/vars')]
print('\n'.join(k for k in keys if k not in live))
")
  if [ -n "$missing" ]; then
    echo "$missing" | sed 's/^/  /;s/$/ is in git but not in the live ConfigMap/'
    echo "    run: kubectl apply -f $SETTINGS   (before pushing)"
    [ $STRICT -eq 1 ] && rc=1
  else
    echo "    ok"
  fi
fi

exit $rc
