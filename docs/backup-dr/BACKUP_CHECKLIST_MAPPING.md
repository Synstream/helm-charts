# Synstream Nonprod: Backup & DR Implementation Status

| Field | Value |
|---|---|
| Document | Backup & DR implementation status (Nonprod) |
| Date | 2026-07-14 |
| Scope | What has been implemented in the backup and disaster-recovery work. |

**Legend:** ✅ Done · 🟡 Partial

---

## Phase 2: Copy the code & assets

| Item | What was done | Status |
|---|---|---|
| Repositories copied | Repositories are cloned and held in the company GitHub organization. | 🟡 |
| Configuration and secrets | Kubernetes Secrets and ConfigMaps for 6 namespaces are exported nightly (application keys, OAuth secrets, license key). | 🟡 |
| CI/CD and deployment manifests | Deployment scripts live in the repositories; workload manifests are exported nightly in the backup. | 🟡 |
| Two copies (cloud + offline) | The encrypted off-node copy in AWS S3 is in place; an additional offline copy is planned. | 🟡 |

## Phase 3: Snapshot live systems

| Item | What was done | Status |
|---|---|---|
| Staging/dev data snapshot | Nonprod data is backed up nightly (data-level). | 🟡 |
| All databases exported | Nightly `pg_dump` of every PostgreSQL database plus the auth store. | ✅ |
| Restore verified | `pg_restore --list` self-verify on every dump, a full restore test, and two persistence tests. | ✅ |

## Phase 4: Credential inventory

| Item | What was done | Status |
|---|---|---|
| Inventory of credentials in use | Credentials are documented across the DR plan and notes; a single consolidated inventory is planned. | 🟡 |
| What each credential unlocks | Partial: the security controls table in the DR plan. | 🟡 |
| Credential rotation plan | Key rotation is documented (roadmap item R4); a broader rotation plan is planned. | 🟡 |

## Phase 5: Knowledge capture

| Item | What was done | Status |
|---|---|---|
| Operational runbook | Restore runbook (DR plan) plus deployment runbooks in scripts and notes. | 🟡 |

---

## Summary

- **Done:** database dumps and verified restore.
- **Partial:** configuration and secrets backup, deployment manifests, credential documentation, restore runbook, and the encrypted off-node (S3) copy.

Full detail is in the backup and DR documentation set (`BACKUP_DR_PLAN`, `BACKUP_SYSTEM_OVERVIEW`).
