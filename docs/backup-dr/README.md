# Nonprod backup & disaster recovery

Runbooks and tooling for backing up and restoring the Synstream **nonprod**
environment: the single-node Kubernetes cluster on AWS EC2 (ap-southeast-1) that
hosts Pipeline Studio, the console, the dashboard demo, and the 40u40
application.

This lives in `helm-charts` because backup and recovery span every service —
`lab-db`, `40u40`, `synstream`, `synstream-dashboard` and `default` alike — so
they belong to none of the per-service repositories, and this is the repository
that already deals with deploying and operating the cluster.

The scripts sit at the repository root under `scripts/`. Nothing here is a Helm
chart and nothing here is packaged by `release.yml`, which only ever touches
`charts/`.

## Contents

| File | What it is |
|---|---|
| `../../scripts/synstream-backup.sh` | Nightly backup. Runs from cron on the node at 02:00. |
| `../../scripts/synstream-restore.sh` | Restore counterpart. Safe by default: databases are staged into `<db>_restore`, destructive steps dry-run unless `--confirm`. |
| `BACKUP_DR_PLAN.md` | The plan of record: scope, schedule, storage, restore runbook, RPO/RTO, security controls, known gaps. |
| `BACKUP_SYSTEM_OVERVIEW.md` | The same system in prose, for a non-operational reader. |
| `BACKUP_CHECKLIST_MAPPING.md` | Maps the DR work onto the single-developer-risk checklist. |
| `s3-lifecycle.json` | S3 lifecycle rules for the backup bucket, applied with `aws s3api put-bucket-lifecycle-configuration`. |
| `*.docx`, `customer/*.docx` | Exports circulated for audit. Generated FROM the Markdown — the `.md` files are the source of truth, and the current exports predate v1.4. |

## Deploying a change

The node runs its own copies under `/opt/synstream-backups/`; nothing pulls from
this repository automatically. After changing a script here, copy it across:

```bash
scp -P 49222 -i ~/.ssh/synstream-k8s-nonprod-key.pem \
  scripts/synstream-restore.sh ubuntu@13.212.75.77:/opt/synstream-backups/
```

Then confirm it runs on the node before trusting it:

```bash
ssh -p 49222 -i ~/.ssh/synstream-k8s-nonprod-key.pem ubuntu@13.212.75.77 \
  "/opt/synstream-backups/synstream-restore.sh --latest --list"
```

## No secrets here

AWS credentials live in `~/.aws/credentials` on the node and the bucket
configuration in `/opt/synstream-backups/s3.env`. Kubernetes Secrets only ever
exist inside a backup archive; anything a restore extracts is written mode 600
and is meant to be deleted afterwards. The repository `.gitignore` blocks
archives, dumps and SQLite files so none of that can be committed by accident.
