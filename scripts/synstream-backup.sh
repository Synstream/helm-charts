#!/usr/bin/env bash
#
# Synstream nonprod backup
# Phase 1: dump everything to a local encrypted-at-rest archive under /opt/synstream-backups
# Phase 2: optionally sync the archive to AWS S3 (activated by creating s3.env)
#
# Scope: Postgres DBs (lab-db + dashboard), auth SQLite, Node-RED flows,
#        k8s Secrets/ConfigMaps/RBAC/NetworkPolicies, Flow/License CRs.
# Container images are NOT in scope: they are rebuilt in CI and published to GHCR
# (ghcr.io/rootsinnovation), or built locally and imported into containerd via ctr.
#
set -uo pipefail

export KUBECONFIG=/home/ubuntu/.kube/config
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

BACKUP_ROOT=/opt/synstream-backups
RETENTION=14
TS=$(date +%Y%m%d-%H%M%S)
WORK="$BACKUP_ROOT/tmp-$TS"
LOG="$BACKUP_ROOT/backup.log"
S3_CONF="$BACKUP_ROOT/s3.env"   # Phase 2: created by the operator, holds bucket/region/prefix

# Write to the log file directly (always), then echo to stdout separately so a
# broken stdout pipe (e.g. a disconnected ssh session) never stops file logging.
log() { local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >> "$LOG"; printf '%s\n' "$m" 2>/dev/null || true; }
fail=0

# Verify a custom-format pg_dump is a readable archive (streams it back into the
# source pod's pg_restore --list). Non-empty listing => archive is not truncated/corrupt.
verify_dump() { # $1=dumpfile  $2=namespace  $3=pod
  local cnt
  cnt=$(cat "$1" 2>/dev/null | kubectl -n "$2" exec -i "$3" -- pg_restore --list 2>/dev/null | wc -l)
  if [ "${cnt:-0}" -ge 1 ]; then log "    verify ok ($cnt archive entries)"; else log "    VERIFY FAILED: $(basename "$1") unreadable"; fail=1; fi
}

mkdir -p "$WORK"/{postgres,sqlite,node-red,k8s}
log "=== backup start $TS ==="

# ---- Postgres: lab-db (pg15) ----
LABDB_POD=$(kubectl -n lab-db get pod -l 'app=postgres-v2' --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$LABDB_POD" ]; then
  for db in test synstream_demo; do
    log "pg_dump lab-db/$db"
    if kubectl -n lab-db exec "$LABDB_POD" -- pg_dump -U postgres -Fc "$db" > "$WORK/postgres/labdb_${db}.dump" 2>>"$LOG"; then
      log "  ok ($(du -h "$WORK/postgres/labdb_${db}.dump" | cut -f1))"
      verify_dump "$WORK/postgres/labdb_${db}.dump" lab-db "$LABDB_POD"
    else
      log "  FAILED lab-db/$db"; fail=1
    fi
  done
else
  log "FAILED: lab-db postgres pod not found"; fail=1
fi

# ---- Postgres: dashboard demo (pg16) ----
DPOD=$(kubectl -n synstream-dashboard get pod -l app=demo-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$DPOD" ]; then
  log "pg_dump dashboard/demo"
  if kubectl -n synstream-dashboard exec "$DPOD" -- pg_dump -U postgres -Fc demo > "$WORK/postgres/dashboard_demo.dump" 2>>"$LOG"; then
    log "  ok ($(du -h "$WORK/postgres/dashboard_demo.dump" | cut -f1))"
    verify_dump "$WORK/postgres/dashboard_demo.dump" synstream-dashboard "$DPOD"
  else
    log "  FAILED dashboard/demo"; fail=1
  fi
else
  log "WARN: dashboard demo-postgres pod not found"
fi

# ---- auth SQLite (WAL-safe) ----
log "backup auth SQLite"
if kubectl -n synstream exec synstream-auth-0 -- sh -c 'command -v sqlite3 >/dev/null 2>&1'; then
  kubectl -n synstream exec synstream-auth-0 -- sh -c 'sqlite3 /app/data/auth.db ".backup /tmp/auth-bk.db"' 2>>"$LOG"
  kubectl -n synstream exec synstream-auth-0 -- cat /tmp/auth-bk.db > "$WORK/sqlite/auth.db" 2>>"$LOG" \
    && log "  ok (sqlite3 .backup)" || { log "  FAILED auth sqlite3"; fail=1; }
  kubectl -n synstream exec synstream-auth-0 -- rm -f /tmp/auth-bk.db 2>>"$LOG"
else
  # No sqlite3 in image: capture main db + WAL + SHM together for a consistent restore
  ok=1
  for f in auth.db auth.db-wal auth.db-shm; do
    kubectl -n synstream exec synstream-auth-0 -- sh -c "test -f /app/data/$f && cat /app/data/$f" > "$WORK/sqlite/$f" 2>>"$LOG" || ok=0
    [ -s "$WORK/sqlite/$f" ] || rm -f "$WORK/sqlite/$f"
  done
  [ "$ok" = 1 ] && log "  ok (raw db+wal+shm)" || { log "  WARN partial auth backup"; }
fi

# ---- Node-RED flows: tar /data of each instance ----
for ns in default 40u40 synstream-dashboard; do
  pod=$(kubectl -n "$ns" get pod -o name 2>/dev/null | grep -E 'pipeline-studio|node-red' | head -1 | cut -d/ -f2)
  if [ -z "$pod" ]; then log "WARN: no node-red pod in $ns"; continue; fi
  log "tar node-red $ns/$pod:/data"
  if kubectl -n "$ns" exec "$pod" -- tar czf - -C / data 2>>"$LOG" > "$WORK/node-red/${ns}_data.tar.gz"; then
    log "  ok ($(du -h "$WORK/node-red/${ns}_data.tar.gz" | cut -f1))"
  else
    log "  FAILED node-red $ns"; fail=1
  fi
done

# ---- k8s Secrets / ConfigMaps + workload/RBAC manifests (for full node-loss rebuild) ----
for ns in synstream synstream-dashboard 40u40 default synstream-system lab-db; do
  kubectl -n "$ns" get secret,configmap -o yaml > "$WORK/k8s/${ns}-secrets-configmaps.yaml" 2>>"$LOG" || log "  WARN export secrets/cm $ns"
  kubectl -n "$ns" get deployment,statefulset,daemonset,service,ingress,persistentvolumeclaim,cronjob,serviceaccount,role,rolebinding,networkpolicy -o yaml \
    > "$WORK/k8s/${ns}-workloads.yaml" 2>>"$LOG" || log "  WARN export workloads $ns"
done
# Cluster-scoped: Flow/License CRs, their CRDs, StorageClasses, and PVs
kubectl get flows.synstream.rtsinv.com,licenses.synstream.rtsinv.com -A -o yaml > "$WORK/k8s/crds-flow-license.yaml" 2>>"$LOG"
kubectl get crd -o yaml > "$WORK/k8s/crd-definitions.yaml" 2>>"$LOG"
kubectl get storageclass,persistentvolume -o yaml > "$WORK/k8s/cluster-storage.yaml" 2>>"$LOG"
log "k8s secrets/configmaps/workloads/rbac/networkpolicy/CRs exported"

# ---- package (restrictive perms: contains secrets) ----
ARCHIVE="$BACKUP_ROOT/synstream-nonprod-$TS.tar.gz"
tar czf "$ARCHIVE" -C "$WORK" . 2>>"$LOG"
chmod 600 "$ARCHIVE"
rm -rf "$WORK"
# Integrity: write a SHA-256 checksum next to the archive (verify later with `sha256sum -c`)
( cd "$BACKUP_ROOT" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
chmod 600 "$ARCHIVE.sha256"
log "archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)), sha256 $(awk '{print substr($1,1,16)}' "$ARCHIVE.sha256")..."

# ---- local retention (archives + their checksums) ----
ls -1t "$BACKUP_ROOT"/synstream-nonprod-*.tar.gz 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
ls -1t "$BACKUP_ROOT"/synstream-nonprod-*.tar.gz.sha256 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
log "retention: keeping newest $RETENTION local archives"

# ---- Phase 2: S3 sync (optional, gated on s3.env) ----
if [ -f "$S3_CONF" ]; then
  # shellcheck disable=SC1090
  . "$S3_CONF"
  if command -v aws >/dev/null 2>&1 && [ -n "${S3_BUCKET:-}" ]; then
    dest="s3://$S3_BUCKET/${S3_PREFIX:-nonprod/}$(basename "$ARCHIVE")"
    log "S3 upload -> $dest"
    if aws s3 cp "$ARCHIVE" "$dest" --sse AES256 ${AWS_REGION:+--region "$AWS_REGION"} >>"$LOG" 2>&1; then
      log "  S3 ok"
      # Upload the checksum too so integrity can be verified against the S3 copy
      if aws s3 cp "$ARCHIVE.sha256" "$dest.sha256" --sse AES256 ${AWS_REGION:+--region "$AWS_REGION"} >>"$LOG" 2>&1; then
        log "  S3 sha256 ok"
      else
        log "  WARN S3 sha256 upload failed"
      fi
    else
      log "  S3 FAILED"; fail=1
    fi
  else
    log "WARN: s3.env present but aws CLI missing or S3_BUCKET empty; local-only this run"
  fi
else
  log "phase2/S3 not configured yet (no $S3_CONF); local backup only"
fi

if [ "$fail" = 0 ]; then
  log "=== DONE ok ==="
  printf 'OK %s\n' "$TS" > "$BACKUP_ROOT/LAST_STATUS"
else
  log "=== DONE with FAILURES ==="
  printf 'FAIL %s\n' "$TS" > "$BACKUP_ROOT/LAST_STATUS"
fi
exit $fail
