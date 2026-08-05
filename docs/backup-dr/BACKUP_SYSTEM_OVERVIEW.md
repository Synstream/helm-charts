# Backing up Synstream nonprod

Synstream nonprod runs on a single Kubernetes node. That keeps it cheap and easy to reason about, but it also means nothing catches us if a pod gets recreated or the box itself dies. For a while there was no backup at all, which is a bad place to be when one of those databases holds real customer data. This writes up the backup system we built to close that gap, what it covers, and how you get data back when something goes wrong.

## The short version

A script on the node runs every night at 2am. It dumps every database, copies the Node-RED flows and the auth store, exports the Kubernetes config, and packs all of it into one archive. That archive stays on the node for two weeks and also gets pushed to an encrypted S3 bucket in Singapore. We ran a restore the same day we built it to confirm the dumps were actually usable, and the nightly job has been running ever since.

That is the whole idea. Everything below is just detail.

## What ends up in a backup

Each run collects the stateful pieces of the platform and nothing else. Anything that can be rebuilt from a container image (the console, the frontend, the operator, and so on) is left out on purpose, because backing it up would just be storing a copy of something we already have. Those images are built in CI and pushed to GHCR (`ghcr.io/rootsinnovation`), or built locally and imported straight into containerd with `ctr`, so after a rebuild you pull or re-import them rather than restore them from a backup. They do not live in AWS ECR.

| What | Where it lives | Roughly |
|---|---|---|
| 40u40 application data | Postgres `test` in `lab-db` | 257 MB |
| Dashboard demo data | Postgres `demo` in `synstream-dashboard` | 47 MB |
| Auth store (users, projects, 2FA) | SQLite `auth.db` in `synstream` | ~1 MB |
| Node-RED flows | `/data` on three instances (main, 40u40, dashboard) | ~300 MB total |
| Cluster config | Secrets, ConfigMaps, workload manifests, Flow/License CRs | small |

The Postgres databases come out through `pg_dump` in the compressed custom format, which is what lets us restore a single table later instead of replaying a whole SQL file. The auth database is SQLite, so we copy it together with its write-ahead log rather than grabbing the file mid-write and hoping it lines up. The Node-RED flows are just a tar of each `/data` directory, credentials included.

The Kubernetes side is worth a mention because it is easy to forget. We export the Secrets and ConfigMaps (where the JWT keys, OAuth secrets, and license key live) along with the actual workload manifests, the custom resource definitions, and the storage classes. The point is that if the node is gone, you can stand up a fresh one and rebuild from the archive without going hunting through Helm charts and old commits.

While we were setting this up we found that two things people assumed were safe actually were not. The `lab-db` Postgres pod, the one with the live 40u40 data, was writing to the container filesystem with no persistent volume behind it. A pod restart would have taken the data with it. The dashboard Node-RED instance had the same problem with its flows. Both are now on their own persistent volumes, migrated across with the data intact and checked byte for byte before we cut over. So the backup is the second line of defense now, not the only one.

Everything gets rolled into a single file, `synstream-nonprod-<timestamp>.tar.gz`, which comes out around 109 MB. It contains secrets, so it is locked down to the owner on disk.

## Where it goes

Two copies, for two different failure modes.

The local copy sits on the node under `/opt/synstream-backups`, and we keep the fourteen most recent. That is the fast path: if someone drops a table or a pod comes back empty, the fix is right there, no network round trip.

The offsite copy goes to an S3 bucket, `synstream-nonprod-backups`, in the Singapore region. That is the one that matters if the whole node disappears. The bucket is dedicated to these backups, has public access blocked outright, encrypts everything at rest with AES-256, and keeps object versions so an overwrite or delete can be walked back. A lifecycle rule ages objects out after 7 days and clears old versions the day after, so it does not grow forever. Both halves matter: with versioning on, expiring an object only hides it behind a delete marker, and the bytes stay (and stay billed) until the old-version rule sweeps them up. The practical effect is a rolling week of offsite archives, which is the trade we made deliberately — anything older than that has to come from the fourteen local copies, and those go with the node.

## How we know it is working

A backup you have never restored is a guess, not a backup. So there are a few checks built in rather than bolted on afterward.

Every database dump is verified the moment it is written. The script reads the dump straight back through `pg_restore --list`, and if that comes back empty or unreadable the run is marked failed then and there. That catches a truncated or corrupt dump at 2am instead of at the worst possible moment weeks later.

Each run also writes a small status file with an OK or FAIL and a timestamp, and logs every step to a file on the node. If you want to know the backup ran and where it stands, that is a one-line check in the morning. On the day we built it we did a full restore end to end, pulled the 40u40 data back out of a dump, and confirmed the expected tables and rows were all there.

## Getting data back

There is a script for this now, `synstream-restore.sh`, sitting next to the backup script on the node. You tell it which archive and which piece you want back, and it checks the archive against its checksum before it opens it, finds the right pod, and does the rest. Databases come back into a scratch copy named `<db>_restore` rather than over the top of the live one, so you get to look at what you restored before anything irreversible happens. The steps that cannot be staged that way, the auth database and the Node-RED flows, print what they are about to do and stop until you pass `--confirm`. Kubernetes manifests it will only unpack, never apply, because the archive holds the whole namespace as it stood that night and applying it wholesale would drag every deployment back with it.

The manual runbook is still in the DR plan for when the script is not an option, and the shape of it is simple. Grab the latest archive, either the local one or a specific version from S3. Unpack it. For a database, feed the relevant dump into the running Postgres pod. For flows, drop the tar back into the Node-RED volume and restart the pod. A single database or a set of flows is back inside an hour. A complete node rebuild, provisioning a new box and restoring from S3, is a half-day job, and the manifests in the archive are there so you are not rebuilding the cluster from memory.

In numbers:

| | Target |
|---|---|
| RPO, the most data you can lose | 24 hours, the gap between nightly runs |
| RTO, one database or flow set | about 1 hour |
| RTO, full node rebuild | about 4 hours |

## What we left out, on purpose

Nonprod is a single node and it is not meant to be highly available, so none of this tries to make it so. The backup protects against losing data, not against downtime while you recover. Worst case, you lose whatever was written since the last 2am run, which is the tradeoff that comes with a nightly cadence. If the business ever needs that window tighter we can move to hourly dumps or ship the write-ahead log, but nobody has asked for that yet, so we did not build it.

There is no paging or Slack alert on a failed run right now. It logs, and that was a deliberate call to keep things simple for the moment rather than an oversight. One item is genuinely still open: the AWS credentials on the node are broader than they need to be and should be scoped down to just this bucket, and the key rotated. That is the last loose thread.

## Where this fits

Backup is one piece of a bigger push to stop the whole platform from living inside one person's accounts and head. That larger checklist covers who actually owns the GitHub org and the cloud accounts, getting a company-held copy of the model weights and container images, writing down how each engine is built and run, handing a walkthrough to a second engineer, and the legal side like IP assignment and NDAs. What is written up here, the data and how to get it back, is the part that is genuinely finished. Most of the rest is still ahead of us. If you want the full checklist and where each item stands, that lives in `BACKUP_CHECKLIST_MAPPING.md` and in section 10.2 of the DR plan.

## Where it stands

The system is in place and running. Nightly job, local plus offsite, encrypted, self-checking, with a tested restore behind it. The two storage gaps we found along the way are fixed. What is left is housekeeping, not building.

## What's next

None of this is urgent, but the backlog is written down so it does not get lost: an alert when a run fails (right now you have to go and look), encrypting the local copies at rest, capturing the node build as code so a rebuild is closer to push-button, and scoping down the AWS key. These are tracked as R4, R7, R8 and R9 in the DR plan. The restore script that used to be on this list is done; what it still needs is a drill against the real cluster, since so far only its handling of the archive itself has been exercised.
