# Backup and restore

The live database is SQLite at `$HOME/openpost-data/db/openpost.db` (override with `OPENPOST_DATA_DIR` or `OPENPOST_DATABASE_PATH`). Media lives on R2. Secrets live in Replit Secrets.

A Reserved VM disk survives a process crash and restart. **A republish or VM recreation wipes the disk.** Treat R2 as the durable copy.

## What is kept

1. **Litestream** (pinned `v0.5.18`) replicates the database continuously to `s3://$OPENPOST_BACKUP_BUCKET/$OPENPOST_LITESTREAM_PREFIX` and snapshots daily, retaining 7 days of snapshots (`snapshot.retention: 168h` in the generated config).
2. **Nightly `sqlite3 .backup`** (plus one run about five minutes after boot) uploads a consistent single-file snapshot to:
   - `$OPENPOST_BACKUP_PREFIX/openpost-latest.db`
   - `$OPENPOST_BACKUP_PREFIX/openpost-YYYYMMDDTHHMMSSZ.db`
3. **R2 versioning** should be enabled on the media (and backups) bucket, once the bucket exists, so deleted media can be undeleted.
4. **Secrets** (`OPENPOST_JWT_SECRET`, `OPENPOST_ENCRYPTION_KEY`, R2 keys) must be copied to the private off-box ops store. A database restore is useless without the same encryption key: OpenPost refuses or cannot decrypt provider tokens if the key differs. The in-app ZIP backup (Settings → Instance → Backup) only works for SQLite plus *local* media, so it does not replace this procedure while media is on R2.

## After a republish (automatic)

`scripts/amhar/start.sh` sees a missing database file and runs `scripts/amhar/restore.sh`, which tries Litestream first and then `openpost-latest.db`. If both fail (first-ever boot), it starts a fresh database.

## Manual backup

```sh
bash scripts/amhar/backup.sh
```

## Manual restore (replaces the local database)

```sh
bash scripts/amhar/restore.sh --force
```

Then restart OpenPost and run `bash scripts/amhar/smoke.sh`.

## Before every upgrade or republish

1. Run `bash scripts/amhar/backup.sh` and confirm the upload line.
2. Record the pinned release tag from `deploy/replit/pin.env`.
3. After the new publish comes up, confirm smoke and that a known workspace still exists (the restore worked).
4. Database migrations are not always reversible. A rollback needs the matching pre-upgrade snapshot plus the previous pinned binary.

## Health

```sh
bash scripts/amhar/health.sh
OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh
```

`/api/v1/health` means the process is up. `/api/v1/ready` must show the database (and storage, when reported) as ok.
