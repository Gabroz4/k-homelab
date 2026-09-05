#!/usr/bin/env bash
#
# bws-rotate.sh — generate-and-write helper for BWS-backed secrets.
#
# Subcommands:
#   gen                 Print a fresh random password (32 alnum chars).
#   lookup <key>        Print the BWS secret UUID for a given key path.
#   get <key>           Print the current value for a key path.
#   set <key> <value>   Write a value to a key.
#   rotate <key>        Generate a new value, write it, print it on stdout.
#
# BWS_ACCESS_TOKEN: if unset, sourced from the in-cluster Secret
# external-secrets/bitwarden-access-token. That token is the same one ESO uses;
# it has write scope on the project pinned below.
#
# Project ID is pinned to the one referenced by the ClusterSecretStore — calls
# to other projects are rejected by BWS anyway, but pinning catches typos early.
#
# Intended to be invoked by the `autorotate-*` Taskfile tasks. Calling the
# write subcommands by hand will clobber a live secret without rolling consumers.

set -euo pipefail

PROJECT_ID="eb7f19cd-99ea-4888-95f7-b41600be7baf"

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_token() {
  if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    BWS_ACCESS_TOKEN=$(kubectl -n external-secrets get secret bitwarden-access-token \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) \
      || die "could not read external-secrets/bitwarden-access-token; set BWS_ACCESS_TOKEN manually"
    [ -n "$BWS_ACCESS_TOKEN" ] || die "in-cluster bitwarden-access-token is empty"
    export BWS_ACCESS_TOKEN
  fi
}

cmd_gen() {
  set +o pipefail
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  set -o pipefail
  echo
}

cmd_lookup() {
  local key="${1:?usage: lookup <key>}"
  ensure_token
  bws secret list "$PROJECT_ID" \
    | jq -er --arg k "$key" '.[] | select(.key==$k) | .id' \
    || die "no BWS secret found for key '$key'"
}

cmd_get() {
  local key="${1:?usage: get <key>}"
  ensure_token
  bws secret list "$PROJECT_ID" \
    | jq -er --arg k "$key" '.[] | select(.key==$k) | .value' \
    || die "no BWS secret found for key '$key'"
}

cmd_set() {
  local key="${1:?usage: set <key> <value>}"
  local value="${2:?usage: set <key> <value>}"
  ensure_token
  local id
  id=$(cmd_lookup "$key")
  bws secret edit --value "$value" "$id" >/dev/null \
    || die "bws secret edit failed for '$key'"
}

cmd_rotate() {
  local key="${1:?usage: rotate <key>}"
  local new
  new=$(cmd_gen)
  cmd_set "$key" "$new"
  printf '%s\n' "$new"
}

case "${1:-}" in
  gen)    shift; cmd_gen "$@" ;;
  lookup) shift; cmd_lookup "$@" ;;
  get)    shift; cmd_get "$@" ;;
  set)    shift; cmd_set "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  *) die "usage: $0 {gen | lookup <key> | get <key> | set <key> <value> | rotate <key>}" ;;
esac
