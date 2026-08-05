#!/usr/bin/env bash
#
# Synstream nonprod restore — the counterpart to synstream-backup.sh.
#
# This exists because the restore path used to be a page of documentation that an
# operator copy-pasted under pressure, which is exactly when a wrong namespace or
# a missing --no-owner costs an hour. Every command here is one that was already
# in the runbook; the script's contribution is that it picks the right pod, checks
# the archive before touching anything, and refuses to overwrite live data unless
# it is told to in so many words.
#
# SAFE BY DEFAULT. Two rules hold everywhere:
#   1. Postgres restores land in a NEW database `<db>_restore`. The live database
#      is untouched until a human compares the two and renames.
#   2. Anything that cannot be done into a scratch copy (SQLite, Node-RED /data)
#      only prints what it would do. Pass --confirm to actually run it.
#
# Kubernetes manifests are never applied automatically at all — see the k8s
# component below for why.
#
# Usage:
#   synstream-restore.sh --list [--archive F | --latest | --from-s3 KEY|latest]
#   synstream-restore.sh --component postgres:test --latest
#   synstream-restore.sh --component node-red:default --latest --confirm
#
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-/home/ubuntu/.kube/config}"
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

BACKUP_ROOT=/opt/synstream-backups
S3_CONF="$BACKUP_ROOT/s3.env"
LOG="$BACKUP_ROOT/restore.log"
WORK=""

# Fall back to /dev/null when the backup directory is not writable — running the
# script from a checkout, or as a user other than `ubuntu`, must not make every
# redirect fail. `2>/dev/null` does not cover this: the shell reports a failed
# redirection before the command it belongs to ever runs, so a bad $LOG would
# take `tar ... 2>>"$LOG"` down with it and the restore would abort on a log file.
if ! ( mkdir -p "$BACKUP_ROOT" 2>/dev/null && touch "$LOG" 2>/dev/null ); then
  LOG=/dev/null
fi

ARCHIVE=""
SOURCE=""          # latest | s3:<key> | file
COMPONENT=""
CONFIRM=0
IN_PLACE=0
LIST_ONLY=0
KEEP=0

log() { local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >> "$LOG" 2>/dev/null; printf '%s\n' "$m" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

cleanup() {
  # Extracted archives hold Kubernetes Secrets in plain YAML, so the working
  # directory is removed on every exit path unless --keep says otherwise.
  if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$KEEP" = 0 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Synstream nonprod restore

Archive selection (pick one):
  --archive FILE        Restore from a specific local archive
  --latest              Newest archive in /opt/synstream-backups
  --from-s3 KEY|latest  Download from S3 first (reads s3.env for bucket/region)

Component (pick one):
  postgres:test               lab-db, DB test          (40u40 business data)
  postgres:synstream_demo     lab-db, DB synstream_demo
  postgres:demo               synstream-dashboard, DB demo
  sqlite:auth                 synstream/synstream-auth-0, /app/data/auth.db
  node-red:default            main distro /data
  node-red:40u40              40u40 /data
  node-red:synstream-dashboard  dashboard Node-RED /data
  k8s:NAMESPACE               extract manifests only, never applies them

Options:
  --list          Show what the archive contains, restore nothing
  --confirm       Actually perform a destructive restore (sqlite, node-red)
  --in-place      Postgres: restore over the live DB instead of <db>_restore.
                  Requires --confirm. Take a fresh backup first.
  --keep          Leave the extracted files in place (they contain Secrets)
  -h, --help      This text

Postgres restores go to <db>_restore by default and print a row count so the
copy can be checked before anyone renames anything.
EOF
}

# ---- arguments --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --archive)   ARCHIVE="${2:-}"; SOURCE="file"; shift 2 ;;
    --latest)    SOURCE="latest"; shift ;;
    --from-s3)   SOURCE="s3:${2:-}"; shift 2 ;;
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --list)      LIST_ONLY=1; shift ;;
    --confirm)   CONFIRM=1; shift ;;
    --in-place)  IN_PLACE=1; shift ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown argument: $1" ;;
  esac
done

[ -n "$SOURCE" ] || { usage; die "no archive selected (--archive, --latest or --from-s3)"; }
[ "$LIST_ONLY" = 1 ] || [ -n "$COMPONENT" ] || { usage; die "no --component selected"; }

# ---- locate the archive -----------------------------------------------------
case "$SOURCE" in
  latest)
    ARCHIVE=$(ls -1t "$BACKUP_ROOT"/synstream-nonprod-*.tar.gz 2>/dev/null | head -1)
    [ -n "$ARCHIVE" ] || die "no local archive in $BACKUP_ROOT"
    ;;
  s3:*)
    key="${SOURCE#s3:}"
    [ -f "$S3_CONF" ] || die "$S3_CONF not found — S3 is not configured on this node"
    # shellcheck disable=SC1090
    . "$S3_CONF"
    [ -n "${S3_BUCKET:-}" ] || die "S3_BUCKET empty in $S3_CONF"
    command -v aws >/dev/null 2>&1 || die "aws CLI not installed"
    prefix="${S3_PREFIX:-nonprod/}"
    if [ "$key" = "latest" ]; then
      key=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" \
              --query 'sort_by(Contents,&LastModified)[-1].Key' --output text \
              ${AWS_REGION:+--region "$AWS_REGION"} 2>>"$LOG")
      # Retention is 7 days: a key that used to exist may already be expired.
      [ -n "$key" ] && [ "$key" != "None" ] || die "no objects under s3://$S3_BUCKET/$prefix"
    fi
    ARCHIVE="/tmp/$(basename "$key")"
    log "downloading s3://$S3_BUCKET/$key"
    aws s3 cp "s3://$S3_BUCKET/$key" "$ARCHIVE" ${AWS_REGION:+--region "$AWS_REGION"} >>"$LOG" 2>&1 \
      || die "S3 download failed"
    # The checksum is uploaded alongside the archive; fetch it so the integrity
    # check below covers the S3 copy too, not just local ones.
    aws s3 cp "s3://$S3_BUCKET/$key.sha256" "$ARCHIVE.sha256" ${AWS_REGION:+--region "$AWS_REGION"} >>"$LOG" 2>&1 \
      || log "WARN: no .sha256 alongside the S3 object"
    ;;
  file)
    [ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
    ;;
esac

log "=== restore start: $(basename "$ARCHIVE") ==="

# ---- integrity --------------------------------------------------------------
# Checked BEFORE extraction, not after. A truncated archive that half-extracts
# over a live /data is worse than one that never opens.
if [ -f "$ARCHIVE.sha256" ]; then
  if ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null 2>&1 ); then
    log "sha256 ok"
  else
    die "sha256 MISMATCH — this archive is corrupt, do not restore from it"
  fi
else
  log "WARN: no checksum file next to the archive; integrity unverified"
fi

# ---- extract ----------------------------------------------------------------
WORK=$(mktemp -d /tmp/synstream-restore-XXXXXX)
chmod 700 "$WORK"
tar xzf "$ARCHIVE" -C "$WORK" 2>>"$LOG" || die "extraction failed"

if [ "$LIST_ONLY" = 1 ]; then
  log "archive contents:"
  ( cd "$WORK" && find . -type f -printf '  %-56p %10s bytes\n' 2>/dev/null || find . -type f )
  exit 0
fi

need() { [ -f "$1" ] || die "not in this archive: ${1#$WORK/}"; }

pick_pod() { # $1=namespace  $2=selector
  kubectl -n "$1" get pod -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG"
}

# Print what a destructive step would do, and stop unless --confirm was given.
gate() {
  if [ "$CONFIRM" = 1 ]; then return 0; fi
  log "DRY RUN — would: $*"
  log "Nothing was changed. Re-run with --confirm to perform it."
  exit 0
}

restore_postgres() { # $1=namespace  $2=selector  $3=db  $4=dumpfile
  local ns="$1" sel="$2" db="$3" dump="$4" pod target
  need "$dump"
  pod=$(pick_pod "$ns" "$sel")
  [ -n "$pod" ] || die "no running pod in $ns matching $sel"
  log "pod: $ns/$pod"

  # Read the dump's table of contents first. This is the same check the backup
  # ran at creation time; running it again here catches an archive that was fine
  # when written and rotted afterwards.
  local entries
  entries=$(kubectl -n "$ns" exec -i "$pod" -- pg_restore --list < "$dump" 2>>"$LOG" | wc -l)
  [ "${entries:-0}" -ge 1 ] || die "dump is unreadable ($entries entries)"
  log "dump readable ($entries archive entries)"

  if [ "$IN_PLACE" = 1 ]; then
    gate "pg_restore --clean --if-exists over the LIVE database $ns/$db"
    target="$db"
    log "restoring OVER live database $db"
    kubectl -n "$ns" exec -i "$pod" -- pg_restore -U postgres -d "$db" --clean --if-exists --no-owner \
      < "$dump" >>"$LOG" 2>&1
  else
    target="${db}_restore"
    log "restoring into scratch database $target (live $db untouched)"
    kubectl -n "$ns" exec -i "$pod" -- psql -U postgres -q -c "DROP DATABASE IF EXISTS ${target};" >>"$LOG" 2>&1
    kubectl -n "$ns" exec -i "$pod" -- psql -U postgres -q -c "CREATE DATABASE ${target};" >>"$LOG" 2>&1
    kubectl -n "$ns" exec -i "$pod" -- pg_restore -U postgres -d "$target" --no-owner \
      < "$dump" >>"$LOG" 2>&1
  fi

  # pg_restore exits non-zero on recoverable warnings (missing role, existing
  # extension), so its status is not a verdict. Count what actually landed.
  local tables
  tables=$(kubectl -n "$ns" exec -i "$pod" -- psql -U postgres -d "$target" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" 2>>"$LOG")
  log "restored: $tables tables in $target"
  [ "${tables:-0}" -ge 1 ] || die "$target has no tables — restore did not work"

  if [ "$IN_PLACE" = 0 ]; then
    log ""
    log "Compare, then cut over during a window:"
    log "  kubectl -n $ns exec -it $pod -- psql -U postgres -d $target"
    log "  ALTER DATABASE $db RENAME TO ${db}_old;  ALTER DATABASE $target RENAME TO $db;"
    log "  (a rename needs no other session connected to either database)"
  fi
}

restore_sqlite() {
  local f="$WORK/sqlite/auth.db"
  need "$f"
  gate "overwrite /app/data/auth.db in synstream/synstream-auth-0 and restart the pod"
  log "copying auth.db into synstream-auth-0"
  kubectl -n synstream cp "$f" synstream-auth-0:/app/data/auth.db >>"$LOG" 2>&1 || die "cp failed"
  # A raw-mode backup carries the write-ahead log; restoring the main db without
  # it would replay a stale WAL over fresh pages.
  for extra in auth.db-wal auth.db-shm; do
    [ -f "$WORK/sqlite/$extra" ] && kubectl -n synstream cp "$WORK/sqlite/$extra" "synstream-auth-0:/app/data/$extra" >>"$LOG" 2>&1
  done
  kubectl -n synstream delete pod synstream-auth-0 >>"$LOG" 2>&1
  log "pod deleted; the StatefulSet recreates it. Verify a login before walking away."
}

restore_nodered() { # $1=namespace
  local ns="$1" f="$WORK/node-red/${1}_data.tar.gz" pod
  need "$f"
  pod=$(kubectl -n "$ns" get pod -o name 2>>"$LOG" | grep -E 'pipeline-studio|node-red' | head -1 | cut -d/ -f2)
  [ -n "$pod" ] || die "no Node-RED pod in namespace $ns"
  gate "extract $(basename "$f") over /data in $ns/$pod and restart it"
  log "copying flows into $ns/$pod"
  kubectl -n "$ns" cp "$f" "$ns/$pod:/tmp/restore-data.tar.gz" >>"$LOG" 2>&1 || die "cp failed"
  kubectl -n "$ns" exec "$pod" -- sh -c 'cd / && tar xzf /tmp/restore-data.tar.gz && rm -f /tmp/restore-data.tar.gz' >>"$LOG" 2>&1 \
    || die "extraction inside the pod failed"
  kubectl -n "$ns" delete pod "$pod" >>"$LOG" 2>&1
  log "pod deleted to reload flows. Check the editor loads before walking away."
}

extract_k8s() { # $1=namespace
  # Deliberately NOT applied. These manifests carry live Secrets and the
  # workload spec as it was on backup night; applying them wholesale would roll
  # every Deployment in the namespace back to that night's image and env. The
  # honest tool here is a diff, which is a human's job.
  local ns="$1"
  local out="/tmp/synstream-restore-k8s-$ns"
  mkdir -p "$out" && chmod 700 "$out"
  local found=0
  for f in "$WORK/k8s/${ns}-secrets-configmaps.yaml" "$WORK/k8s/${ns}-workloads.yaml"; do
    [ -f "$f" ] && cp "$f" "$out/" && found=1
  done
  for f in "$WORK/k8s/crds-flow-license.yaml" "$WORK/k8s/crd-definitions.yaml" "$WORK/k8s/cluster-storage.yaml"; do
    [ -f "$f" ] && cp "$f" "$out/"
  done
  [ "$found" = 1 ] || die "no manifests for namespace $ns in this archive"
  chmod 600 "$out"/*
  # $out sits outside WORK on purpose: the operator needs these after the script
  # exits, while WORK — which holds every OTHER namespace's Secrets too — must
  # still be wiped by the exit trap.
  log "manifests extracted to $out (mode 600 — they contain Secrets)"
  log ""
  log "Review, then apply only what you mean to:"
  log "  kubectl diff -f $out/${ns}-secrets-configmaps.yaml"
  log "  kubectl apply -f $out/${ns}-secrets-configmaps.yaml"
  log "Delete them when done: rm -rf $out"
}

# ---- dispatch ---------------------------------------------------------------
case "$COMPONENT" in
  postgres:test)           restore_postgres lab-db "app=postgres-v2" test "$WORK/postgres/labdb_test.dump" ;;
  postgres:synstream_demo) restore_postgres lab-db "app=postgres-v2" synstream_demo "$WORK/postgres/labdb_synstream_demo.dump" ;;
  postgres:demo)           restore_postgres synstream-dashboard "app=demo-postgres" demo "$WORK/postgres/dashboard_demo.dump" ;;
  sqlite:auth)             restore_sqlite ;;
  node-red:*)              restore_nodered "${COMPONENT#node-red:}" ;;
  k8s:*)                   extract_k8s "${COMPONENT#k8s:}" ;;
  *)                       usage; die "unknown component: $COMPONENT" ;;
esac

log "=== restore done ==="
