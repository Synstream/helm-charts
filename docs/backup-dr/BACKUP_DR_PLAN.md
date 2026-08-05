# Synstream Nonprod: Backup & Disaster Recovery Plan

| Field | Value |
|---|---|
| Document | Backup & Disaster Recovery Plan (Nonprod) |
| Version | 1.4 |
| Date | 2026-08-05 |
| Environment | Nonprod (single-node Kubernetes, AWS EC2, ap-southeast-1) |
| Owner | Synstream Platform / DevOps |
| Audience | Internal DevOps + external technical audit (ASUS, NVIDIA) |
| Status | Active. Local and off-node (S3) tiers implemented and verified; restore is scripted (Section 6.1). Sits within the broader Backup & Access-Control Checklist (see Section 10.2). |

**Changes in 1.4 (2026-08-05):** S3 retention shortened from 90/30 days to 7/1 (Section 4.3, 4.5) and the lifecycle rules are now version-controlled. Restore is no longer copy-paste only: `scripts/synstream-restore.sh` implements the runbook (Section 6.1), closing gap R10.

---

## 1. Executive summary

This document describes backup and disaster recovery (DR) for the Synstream nonprod environment: scope, schedule, storage, restore procedures, recovery objectives, security controls, and known gaps. Container images are out of data-backup scope: they are reproducible and are re-pulled or re-imported from the container registry rather than restored from an archive (Section 2.2).

An automated daily backup has been in place since 2026-07-14. A cron job runs every night at 02:00 server time, dumps all stateful components into a single archive on the node, and uploads it to an AWS S3 bucket with server-side encryption, versioning, and lifecycle rotation. Restores were verified the same day: a PostgreSQL dump passed `pg_restore --list` validation and the Node-RED flow files were confirmed present in the archive.

Nonprod runs on a single Kubernetes node and is not highly available by design. The backup system protects against data loss (accidental deletion, pod re-creation, database corruption) and gives a documented recovery path for node loss. Full high availability is out of scope for nonprod; see Section 10.

Backup is one part of a wider effort to remove single-developer risk, tracked in the Synstream Backup & Access-Control Checklist (owner: Ivan Cham). This document covers the data-protection portion of that effort: it fully addresses the "export every database" and "verify a restore" items of the checklist and contributes to the code/config and credential items. The ownership lockdown, asset copying, credential inventory, knowledge handover, and legal items sit outside backup and are summarised against the checklist in Section 10.2.

---

## 2. Systems inventory (scope)

Single control-plane Kubernetes node (`ip-172-31-44-180`), AWS EC2, Ubuntu 24.04, Kubernetes v1.32, container runtime containerd. Ingress via ingress-nginx, TLS via cert-manager.

### 2.1 Stateful components (in backup scope)

| Component | Namespace | Data store | Location | Size (approx) | Public endpoint |
|---|---|---|---|---|---|
| 40u40 application DB | `lab-db` | PostgreSQL 15, DB `test` | PVC `postgres-data` (10 GiB) | 257 MB | (internal) |
| Secondary DB | `lab-db` | PostgreSQL 15, DB `synstream_demo` | PVC `postgres-data` (10 GiB) | 8 MB | (internal) |
| Dashboard demo DB | `synstream-dashboard` | PostgreSQL 16, DB `demo` | PVC (2 GiB) | 47 MB | (internal) |
| Auth service | `synstream` | SQLite `auth.db` | PVC (1 GiB) | ~1 MB | console-page.nonprod.rtsinv.com |
| Node-RED (main distro) | `default` | flows on PVC (10 GiB) | `/data` | 157 MB | pipeline-studio.nonprod.rtsinv.com |
| Node-RED (40u40) | `40u40` | flows on PVC (10 GiB) | `/data` | 128 MB | pipeline-studio-40u40.nonprod.rtsinv.com |
| Node-RED (dashboard) | `synstream-dashboard` | flows on PVC `node-red-data` (10 GiB) | `/data` | ~14 MB | dashboard-pipeline.nonprod.rtsinv.com |
| Kubernetes config | (all) | Secrets, ConfigMaps, workload manifests, RBAC (Roles/RoleBindings), NetworkPolicies, Flow/License CRs | etcd | small | n/a |

### 2.2 Stateless components (rebuilt from images, not backed up as data)

Console frontend, auth service binary, manager, operator, nginx, frontend/BFF for the dashboard. These are recovered by re-deploying their container images and applying the backed-up Kubernetes manifests (Secrets/ConfigMaps/RBAC/CRs).

**Container images** are not part of the data backup because they are reproducible rather than stateful. Images are built in CI and published to the GitHub Container Registry (`ghcr.io/rootsinnovation/<service>`); for this single-node environment several are built locally and imported directly into containerd with `ctr` (this cluster does not pull from AWS ECR). Recovery is therefore a re-pull from GHCR or a re-import, not a restore from the archive. Images are tagged per release (for example `lic136-gw3`) so a specific version can be reproduced.

### 2.3 Licensing

License is managed by a `License` custom resource (`synstream-license`): currently Valid, type enterprise, 500 max flows, expires 2027-05-13. The License and Flow custom resources are included in the configuration backup.

---

## 3. Data classification & criticality

| Data | Criticality | Rationale |
|---|---|---|
| `lab-db` DB `test` | Critical | Real 40u40 business data (leads, accounts, outreach, funnel history). No other copy. |
| Node-RED flows (all) | High | ETL pipeline definitions and credentials. Rebuild is manual and slow. |
| Auth SQLite | High | Users, projects, 2FA secrets. Loss forces re-provisioning of access. |
| K8s Secrets/ConfigMaps/CRs | High | JWT/encryption keys, OAuth secrets, license key. Loss breaks auth and licensing. |
| `synstream_demo`, dashboard `demo` | Low | Demo/sample data. |

### 3.1 Business impact analysis

| Service | Depends on | Impact if lost | Recovery priority |
|---|---|---|---|
| 40u40 application | lab-db `test`, Node-RED (40u40) flows | Loss of real leads/accounts data and the pipelines that maintain it | 1 (highest) |
| Auth / console access | Auth SQLite, K8s Secrets (JWT/encryption keys) | Users cannot log in; access must be re-provisioned | 1 |
| Pipeline Studio (main) | Node-RED (default) flows, License CR | ETL pipelines stop and must be rebuilt by hand | 2 |
| Licensing | License CR, operator | Flows are blocked once the license cannot be validated | 2 |
| Dashboard demo | dashboard `demo` DB, Node-RED (dashboard) flows | Demo/sales environment degraded; no real data at risk | 3 |

---

## 4. Backup strategy

### 4.1 What is backed up

The backup job (`/opt/synstream-backups/synstream-backup.sh`) captures, per run:

- **PostgreSQL**: `pg_dump -Fc` (custom format, compressed) for `test`, `synstream_demo` (lab-db) and `demo` (dashboard).
- **Auth SQLite**: a consistent copy of `auth.db` including its write-ahead log (WAL) so in-flight transactions are not lost.
- **Node-RED flows**: a gzip tar of `/data` for each of the three instances (contains `flows.json`, `flows_cred.json`, `settings.js`).
- **Kubernetes configuration**: for 6 namespaces, `Secret` and `ConfigMap` objects plus workload and access-control manifests (`Deployment`, `StatefulSet`, `DaemonSet`, `Service`, `Ingress`, `PersistentVolumeClaim`, `CronJob`, `ServiceAccount`, `Role`, `RoleBinding`, `NetworkPolicy`). Cluster-scoped: `Flow`/`License` custom resources and their CRD definitions, `StorageClass` and `PersistentVolume` objects. Exported as YAML. This makes a full node-loss rebuild reproducible from the archive.

Each PostgreSQL dump is self-verified after creation (`pg_restore --list` must return a readable archive listing) so a truncated or corrupt dump is caught at backup time, not at restore time.

All artifacts are packaged into a single archive: `synstream-nonprod-<TIMESTAMP>.tar.gz` (approx 109 MB per run). A SHA-256 checksum is written next to it (`<archive>.sha256`) and uploaded alongside it to S3, so the integrity of either the local or the off-node copy can be confirmed with `sha256sum -c`.

### 4.2 Schedule

Daily at 02:00 server time, via cron (`/etc/cron.d/synstream-backup`, runs as user `ubuntu`).

### 4.3 Storage tiers

| Tier | Location | Purpose | Retention |
|---|---|---|---|
| Local (on-node) | `/opt/synstream-backups/` (perms 0700, archives 0600) | Fast restore, protects against pod/DB-level loss | 14 most-recent archives |
| Off-node (S3) | `s3://synstream-nonprod-backups/nonprod/` (ap-southeast-1) | Off-node DR, protects against node loss | Lifecycle: current 7 days, noncurrent versions 1 day |

S3 retention was shortened from 90/30 days to 7/1 on 2026-08-05. Because S3 rounds an expiration up to the next UTC midnight, a 02:00 archive under a 7-day rule is removed at 00:00 UTC on day 8, so the bucket settles at 8 archives rather than 7.

The trade-off this accepts: the recoverable window off-node is now about a week. Silent corruption discovered on day 9 cannot be recovered from S3 and would depend on the 14 local archives, which are lost with the node. This is accepted for nonprod; `lab-db` `test` is the one dataset classified Critical with no other copy (Section 3), and a longer per-prefix rule for it remains available at negligible cost if that risk is later judged too high.

### 4.4 Encryption

- **In transit**: HTTPS (AWS SDK TLS) to S3.
- **At rest (local)**: archive files are not encrypted; they are restricted to owner (0600) on the node. Off-node copies are encrypted (below).
- **At rest (S3)**: server-side encryption `SSE-S3` (AES-256), verified on uploaded objects. Bucket default encryption is also enabled.

### 4.5 S3 bucket controls

Bucket `synstream-nonprod-backups` (dedicated, not shared with other projects):

- Block Public Access: all four settings enabled.
- Default encryption: SSE-S3 (AES-256).
- Versioning: enabled (protects against overwrite/delete).
- Lifecycle (rule `expire-nonprod-backups-7d`, prefix `nonprod/`): expire current objects after 7 days, delete noncurrent versions after 1 day, abort incomplete multipart uploads after 1 day. A second rule removes expired delete markers.

Both `NoncurrentVersionExpiration` and `Expiration` are set deliberately. With versioning enabled, expiring a current object only writes a delete marker — the bytes survive (and are billed) until the noncurrent rule removes them, so an `Expiration` of 7 days paired with the previous noncurrent rule of 30 would have retained data for 37 days.

The lifecycle configuration is version-controlled at `docs/backup-dr/s3-lifecycle.json` and applied with:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket synstream-nonprod-backups \
  --lifecycle-configuration file://s3-lifecycle.json \
  --region ap-southeast-1
```

Lifecycle runs as an asynchronous daily batch job; it cannot be triggered on demand. To confirm a rule matched without waiting for the sweep, read the `Expiration` header of any object — it reports the computed expiry date and the rule id that produced it:

```bash
aws s3api head-object --bucket synstream-nonprod-backups \
  --key nonprod/<archive> --query 'Expiration' --region ap-southeast-1
```

---

## 5. Recovery objectives (RPO / RTO)

| Metric | Target (nonprod) | Basis |
|---|---|---|
| RPO (max data loss) | 24 hours | Daily backup cadence. Worst case is data written since the last 02:00 run. |
| RTO (single DB restore) | ≤ 1 hour | Restore one `pg_dump` into the running pod. |
| RTO (pod/flow recovery) | ≤ 1 hour | Extract archive, restore DB or flows, restart pod. |
| RTO (full node loss) | ≤ 4 hours | Provision new node, install Kubernetes + CRDs, re-deploy images, apply manifests, restore data from S3. |

RPO can be tightened later (hourly Postgres dumps or WAL archiving) if the business requires it; see the remediation roadmap.

---

## 6. Restore runbook

All commands run from the node as user `ubuntu` (kubeconfig at `/home/ubuntu/.kube/config`).

### 6.1 Scripted restore (preferred)

`scripts/synstream-restore.sh` (deployed to `/opt/synstream-backups/synstream-restore.sh`) performs every step in this section. Prefer it over the manual commands: it verifies the archive checksum before extracting anything, selects the correct pod, and will not overwrite live data unless explicitly told to.

Two safety rules are built in:

1. **PostgreSQL restores land in a new database `<db>_restore`.** The live database is untouched until an operator has compared the two and renamed. `--in-place` restores over the live database and requires `--confirm`.
2. **Steps that cannot be staged (auth SQLite, Node-RED `/data`) print what they would do and stop.** They run only with `--confirm`.

Kubernetes manifests are never applied automatically. The archive holds the workload spec as it was on backup night, so applying it wholesale would roll every Deployment in the namespace back to that night's image and environment. `--component k8s:<namespace>` extracts the manifests to `/tmp` (mode 600, they contain Secrets) and prints the `kubectl diff` / `kubectl apply` commands for a human to run selectively.

```bash
# Inspect an archive without restoring
/opt/synstream-backups/synstream-restore.sh --latest --list

# Stage a PostgreSQL restore into test_restore (live `test` untouched)
/opt/synstream-backups/synstream-restore.sh --latest --component postgres:test

# Pull the newest archive from S3 instead of using a local one
/opt/synstream-backups/synstream-restore.sh --from-s3 latest --component postgres:demo

# Restore Node-RED flows (destructive — dry-runs without --confirm)
/opt/synstream-backups/synstream-restore.sh --latest --component node-red:default --confirm
```

Components: `postgres:test`, `postgres:synstream_demo`, `postgres:demo`, `sqlite:auth`, `node-red:default`, `node-red:40u40`, `node-red:synstream-dashboard`, `k8s:<namespace>`. Run `--help` for the full list. Every run appends to `/opt/synstream-backups/restore.log`.

After a staged PostgreSQL restore the script reports the table count in `<db>_restore`. `pg_restore` exits non-zero on recoverable warnings (a missing role, an existing extension), so its exit status is not a verdict — the table count is.

**Verification status.** The script's archive handling — checksum verification, rejection of a corrupt archive, extraction, component dispatch, and the dry-run gate on destructive steps — was tested against a synthetic archive on 2026-08-05. Its cluster-facing paths (`pg_restore` into a live pod, the SQLite and Node-RED copies) have not yet been exercised against the node; that is the next restore drill (Section 8.1).

The remaining subsections document the same operations by hand, for use when the script is unavailable or when a restore has to deviate from it.

### 6.2 Obtain a backup archive

```bash
# Latest local archive
ls -1t /opt/synstream-backups/synstream-nonprod-*.tar.gz | head -1

# Or pull a specific archive from S3
aws s3 ls s3://synstream-nonprod-backups/nonprod/
aws s3 cp s3://synstream-nonprod-backups/nonprod/synstream-nonprod-<TS>.tar.gz /tmp/

# Extract (archive entries are prefixed with ./)
mkdir -p /tmp/restore && tar xzf /tmp/synstream-nonprod-<TS>.tar.gz -C /tmp/restore
ls -R /tmp/restore
```

### 6.3 Restore a PostgreSQL database (lab-db `test`)

```bash
POD=$(kubectl -n lab-db get pod -l 'app in (postgres,postgres-v2)' --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# Optional: inspect the dump before restoring
cat /tmp/restore/postgres/labdb_test.dump | kubectl -n lab-db exec -i "$POD" -- pg_restore --list | head

# Restore into a fresh database (safest): drop/recreate then restore
kubectl -n lab-db exec -i "$POD" -- psql -U postgres -c "DROP DATABASE IF EXISTS test_restore;" 
kubectl -n lab-db exec -i "$POD" -- psql -U postgres -c "CREATE DATABASE test_restore;"
cat /tmp/restore/postgres/labdb_test.dump | kubectl -n lab-db exec -i "$POD" -- pg_restore -U postgres -d test_restore --no-owner

# Verify, then cut over (rename) during a maintenance window
kubectl -n lab-db exec -i "$POD" -- psql -U postgres -d test_restore -c "SELECT count(*) FROM u40_lead;"
```

To restore in place over the existing `test` database, use `pg_restore -d test --clean --if-exists` instead (this drops and recreates objects; take a fresh backup first). Same procedure for `synstream_demo` (lab-db) and `demo` (namespace `synstream-dashboard`, label `app=demo-postgres`).

### 6.4 Restore auth SQLite

```bash
# Copy the backed-up db back into the auth pod, then restart it
kubectl -n synstream cp /tmp/restore/sqlite/auth.db synstream-auth-0:/app/data/auth.db
kubectl -n synstream delete pod synstream-auth-0    # StatefulSet recreates it
```

If the backup contains `auth.db-wal`/`auth.db-shm` (raw mode), copy all three files together before restarting.

### 6.5 Restore Node-RED flows

```bash
# Example: main distro (namespace default)
POD=$(kubectl -n default get pod -o name | grep pipeline-studio | head -1 | cut -d/ -f2)

# Copy the flow tar into the pod and extract over /data
kubectl -n default cp /tmp/restore/node-red/default_data.tar.gz "$POD":/tmp/data.tar.gz
kubectl -n default exec "$POD" -- sh -c 'cd / && tar xzf /tmp/data.tar.gz && rm /tmp/data.tar.gz'
kubectl -n default delete pod "$POD"    # restart to reload flows
```

### 6.6 Restore Kubernetes Secrets / ConfigMaps / CRs

```bash
# Review before applying (contains sensitive keys)
less /tmp/restore/k8s/synstream.yaml

# Apply per namespace
kubectl apply -f /tmp/restore/k8s/synstream.yaml
kubectl apply -f /tmp/restore/k8s/synstream-dashboard.yaml
# ... repeat for each namespace file

# Flow and License custom resources
kubectl apply -f /tmp/restore/k8s/crds-flow-license.yaml
```

### 6.7 Clean up

```bash
rm -rf /tmp/restore /tmp/synstream-nonprod-*.tar.gz
```

---

## 7. Disaster recovery scenarios

### 7.1 Accidental data deletion or DB corruption
Restore the affected database or flow from the latest archive (Sections 6.3 to 6.5). RTO ≤ 1 hour, RPO ≤ 24 hours.

### 7.2 Pod re-created and ephemeral data lost
The `lab-db` PostgreSQL database (R1) and the dashboard Node-RED userDir (R2) are both now persisted on PVCs and survive pod re-creation, each confirmed by a pod-deletion persistence test on 2026-07-14. For any component still on ephemeral storage, restore from the latest archive after the pod comes back. RTO ≤ 1 hour.

### 7.3 Full node loss

Node provisioning is currently a manual runbook; there is no Infrastructure-as-Code for this environment yet (see roadmap item R9). The steps are:

1. Provision a new EC2 node (same size, ap-southeast-1).
2. Install Kubernetes (kubeadm), CNI (flannel), ingress-nginx, cert-manager, local-path provisioner.
3. Install Synstream CRDs (`kubectl apply -f synstream-operator/config/crd/bases/`).
4. Restore the container images: re-pull from GHCR (`ghcr.io/rootsinnovation`) or re-import the locally-built images into containerd with `ctr`.
5. Apply the backed-up Kubernetes manifests from the archive (Secrets, ConfigMaps, workloads, RBAC, NetworkPolicies, StorageClasses).
6. Download the latest archive from S3, verify it with `sha256sum -c`, then run the restore runbook (Sections 6.3 to 6.6).
7. Validate endpoints and license status.

RTO ≤ 4 hours, RPO ≤ 24 hours.

### 7.4 S3 / region unavailability
Local archives (14 days) remain available on the node for restore. Backups resume to S3 automatically when access is restored.

---

## 8. Verification & monitoring

- **Log**: every run appends to `/opt/synstream-backups/backup.log` with per-step status and a final `=== DONE ok ===` or `=== DONE with FAILURES ===` line. Cron output is captured to `/opt/synstream-backups/cron.log`.
- **Status file**: each run writes `/opt/synstream-backups/LAST_STATUS` (`OK <timestamp>` or `FAIL <timestamp>`) for quick health checks and future automated monitoring.
- **Integrity**: each PostgreSQL dump is self-verified at backup time (`pg_restore --list`), and each archive carries a SHA-256 checksum that is uploaded with it to S3, so any copy can be checked with `sha256sum -c`. A full test restore was executed successfully on 2026-07-14 (`u40_lead` / `u40_account` present, 14 data tables), and a pod-deletion persistence test confirmed the migrated `lab-db` data survives pod re-creation on its PVC.
- **Recommended checks** (operational):
  - Confirm a new object appears daily: `aws s3 ls s3://synstream-nonprod-backups/nonprod/`
  - Tail the log after 02:00: `tail -20 /opt/synstream-backups/backup.log`
  - Perform a quarterly full restore drill (see Section 6) and record the result in Section 8.1.

### 8.1 Disaster recovery drill history

| Date | Type | Scope | Result | Notes |
|---|---|---|---|---|
| 2026-07-14 | Restore validation | lab-db `test`, full restore from a `pg_dump` archive | Pass | `u40_lead` / `u40_account` present, 14 data tables restored |
| 2026-07-14 | Persistence test | lab-db and dashboard Node-RED PVCs, pod deletion | Pass | Data and flows survived pod re-creation |
| Q4 2026 (planned) | Full restore drill | End-to-end restore into a scratch namespace | Pending | Quarterly cadence |

---

## 9. Security controls

| Control | Implementation |
|---|---|
| Encryption at rest (S3) | SSE-S3 (AES-256), bucket default + per-object, verified |
| Encryption in transit | TLS to S3 |
| Local file protection | Backup directory 0700, archives 0600, owned by `ubuntu` |
| Public access | S3 Block Public Access fully enabled |
| Immutability | S3 versioning enabled (recover overwritten/deleted objects) |
| Credential handling | AWS credentials stored on the node via `aws configure` (not embedded in scripts or committed to source control) |
| Least privilege | See remediation roadmap item R4 (currently the IAM user has broad access; scope-down recommended) |

---

## 10. Known gaps & remediation roadmap

Backup and DR is the data-protection slice of a broader effort to remove single-developer risk (the Synstream Backup & Access-Control Checklist, owner Ivan Cham). Section 10.1 lists the technical backup/DR gaps. Section 10.2 places backup within the full checklist and shows what remains outside it.

### 10.1 Backup / DR technical gaps

| ID | Gap | Severity | Remediation | Status |
|---|---|---|---|---|
| R1 | `lab-db` PostgreSQL had no persistent volume; data lived on the container filesystem and would be lost if the pod were re-created. | Critical | Resolved 2026-07-14. Migrated to PVC `postgres-data` (10 GiB) via a parallel pod plus service cutover (near-zero downtime). Data parity verified (all 18 relations identical, zero drift). The old ephemeral deployment was deleted after verification and the backup pod selector pinned to `app=postgres-v2`. | Done |
| R2 | Dashboard Node-RED userDir (`/data`: flows, credentials, seeded agents, installed palette nodes) was not persisted (no volume); a pod restart or redeploy would wipe it. | High | Resolved 2026-07-14. Created PVC `node-red-data` (10 GiB) and migrated the existing 121 MB userDir with byte-for-byte parity (3,256 files, 115,793,715 bytes) via a helper pod, then mounted it at `/data` (Recreate strategy). Persistence verified by a pod-deletion test. Source manifest (`deploy/k8s.yaml`) updated so future redeploys keep the volume. | Done |
| R3 | Single-node cluster; all volumes use `local-path` with reclaim policy Delete. Node loss loses all local data. | High (accepted for nonprod) | Off-node S3 backup implemented. Full HA is out of scope for nonprod. | Mitigated |
| R4 | Backup IAM user has broad permissions. | Medium | Restrict to `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the backup bucket only, and rotate the historical credential as part of routine security hardening. | Recommended |
| R5 | RPO is 24 hours. | Medium | Optional: hourly Postgres dumps or WAL archiving if business requires a tighter RPO. | Optional |
| R6 | Disk usage on the node is ~73% (70 GB of 96 GB, 27 GB free). | Low | Monitor. A PV audit on 2026-07-14 found no orphaned volumes (all five PVs are bound). If disk pressure rises, prune unused container images and rotate logs; local backup retention (14 archives) caps its own growth. | Monitor |
| R7 | No external backup alerting; a failure is visible only in the on-node log and status file. | Medium | Add a notification channel (CloudWatch alarm, Slack, or email) and a dead-man check that the daily run actually happened. | Planned |
| R8 | Local archives are not encrypted at rest; they rely on 0600 file permissions (only the S3 copy is encrypted). | Medium | Encrypt local archives at rest (for example GPG or age) with keys held off the node. | Planned |
| R9 | Node provisioning is manual; there is no Infrastructure-as-Code. | Low | Capture the node build (kubeadm, CNI, ingress, cert-manager, provisioner) as Terraform or Ansible so a rebuild is reproducible. | Planned |
| R10 | Restore is a manual runbook. | Low | Resolved 2026-08-05. `scripts/synstream-restore.sh` verifies the archive checksum, selects the pod, and restores a chosen database, SQLite file or flow set. PostgreSQL restores stage into `<db>_restore` and destructive steps dry-run unless `--confirm` is passed, so the default path cannot damage live data. See Section 6.1. | Done |
| R11 | Off-node recovery window is 7 days (retention shortened 2026-08-05). Corruption found later than that cannot be recovered from S3. | Medium (accepted) | Optionally add a longer-retention lifecycle rule scoped to the `lab-db` `test` prefix, the one Critical dataset with no other copy. | Accepted |

### 10.2 Single-developer-risk checklist coverage

The checklist has six phases; backup and DR (this document) covers only part of it. The table below is the phase-level view. A line-by-line mapping of every checklist item to the evidence is maintained separately in `BACKUP_CHECKLIST_MAPPING.md`.

| Checklist phase | Overall status | What backup / DR contributes | Owner / next step (outside backup) |
|---|---|---|---|
| 1. Lock ownership & access | Open | None (governance, not a data task) | Confirm the company (not an individual) owns the GitHub org, cloud root accounts, domain/DNS, Workspace/M365, NVIDIA and Panasonic accounts, and SaaS billing; create parallel owner/admin credentials and store them in a company password manager. |
| 2. Copy the code & assets | Partial | Kubernetes Secrets, ConfigMaps, and workload manifests exported nightly; repos live in the company GitHub org | Add AI model weights and datasets (Engine 1/2/3), container images, and the issue tracker/wiki to a company-controlled store, and hold a second (offline) copy. |
| 3. Snapshot live systems | Partial (DB + restore done) | All databases dumped nightly and a restore was verified end to end | Add full VM/disk snapshots and Jetson/edge device configuration capture. |
| 4. Credential inventory | Partial | Security controls documented (Section 9); AWS key rotation planned (R4) | Consolidate a single inventory of every credential, what each unlocks, and a rotation plan for point-of-departure. |
| 5. Knowledge capture | Partial | This document is the backup/restore runbook | Produce an architecture diagram (all engines + data flow), a build/deploy/restart/troubleshoot runbook per engine, a recorded walkthrough, and grant read-access plus a walkthrough to a second engineer. |
| 6. Legal footing | Open | None (legal) | Confirm a signed IP assignment (all code and models belong to Synstream) and that an NDA plus non-solicit are in place. |

---

## 11. Audit checklist

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Documented backup policy exists | Yes | This document |
| 2 | Backups are automated (not manual) | Yes | cron `/etc/cron.d/synstream-backup`, daily 02:00 |
| 3 | All critical data in scope | Yes | Section 2.1 / Section 4.1 |
| 4 | Off-site / off-node copy | Yes | AWS S3, ap-southeast-1 |
| 5 | Encryption at rest | Yes | SSE-S3 AES-256 on S3 (verified); local copies rely on file permissions |
| 6 | Encryption in transit | Yes | TLS to S3 |
| 7 | Access controls on backups | Yes | Block Public Access; local 0600; IAM (scope-down pending, R4) |
| 8 | Defined retention policy | Yes | Local 14 archives; S3 lifecycle 7/1 days, version-controlled at `docs/backup-dr/s3-lifecycle.json` |
| 9 | Documented restore procedure | Yes | Section 6 (runbook) + `scripts/synstream-restore.sh` (Section 6.1) |
| 10 | Restore tested / verified | Yes | 2026-07-14 pg_restore validation; recurring drill recommended |
| 11 | RPO / RTO defined | Yes | Section 5 |
| 12 | DR scenarios documented | Yes | Section 7 |
| 13 | Backup monitoring / alerting | Partial | `backup.log` + `cron.log` + `LAST_STATUS` file on node; external alerting channel (Slack/email/dead-man switch) is a planned follow-up |
| 14 | Immutable / versioned backups | Yes | S3 versioning enabled |

---

## 12. Appendix: key locations

| Item | Path / Value |
|---|---|
| Backup script | `/opt/synstream-backups/synstream-backup.sh` (node) |
| Restore script | `/opt/synstream-backups/synstream-restore.sh` (node) |
| Source copies | `scripts/synstream-backup.sh`, `scripts/synstream-restore.sh` (this repo) |
| S3 lifecycle config | `docs/backup-dr/s3-lifecycle.json` (this repo) |
| Restore log | `/opt/synstream-backups/restore.log` |
| Cron | `/etc/cron.d/synstream-backup` (daily 02:00, user `ubuntu`) |
| Local archives | `/opt/synstream-backups/synstream-nonprod-*.tar.gz` |
| Log | `/opt/synstream-backups/backup.log` |
| Phase-2 config | `/opt/synstream-backups/s3.env` (bucket/region/prefix, non-secret) |
| S3 destination | `s3://synstream-nonprod-backups/nonprod/` (ap-southeast-1) |
| AWS credentials | `~/.aws/credentials` on node (user `ubuntu`); not in source control |

---

*Prepared 2026-07-14. Review quarterly or after any significant infrastructure change.*
