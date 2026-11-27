# Backup and restore

The live database is SQLite at `$HOME/openpost-data/db/openpost.db` (override with `OPENPOST_DATA_DIR` or `OPENPOST_DATABASE_PATH`). Media lives on R2. Secrets live in Replit Secrets.

A Reserved VM disk survives a process crash and restart. **A republish or VM recreation wipes the disk.** Treat R2 as the durable copy.

## What is kept

1. **Litestream** (pinned `v0.5.18`) replicates the database continuously. Every boot that restores (or starts fresh) writes to its **own generation path**: `s3://$OPENPOST_BACKUP_BUCKET/$OPENPOST_LITESTREAM_GEN_ROOT/<generation>/` (default root `backups/litestream-gen`; a generation id looks like `20261127T001500Z-a1b2c3`). The id is kept in `$OPENPOST_DATA_DIR/generation`, so a plain process restart on the same VM keeps writing to the same path. Daily snapshots (aligned to 00:00 UTC, 03:00 Baghdad) are retained for 7 days.
2. **The legacy path** `backups/litestream` (`$OPENPOST_LITESTREAM_PREFIX`) is now **read-only**. Restores still consider it, but nothing new writes there.
3. **`sqlite3 .backup` snapshots**, ten minutes after boot and then every 24 hours, uploaded with curl (`scripts/amhar/r2.sh`; the deploy image has no python3):
   - `$OPENPOST_BACKUP_PREFIX/<generation>/openpost-YYYYMMDDTHHMMSSZ.db`
   - `$OPENPOST_BACKUP_PREFIX/openpost-latest.db` (only when the snapshot has at least one user)
4. **R2 versioning** should be enabled on the media (and backups) bucket, once the bucket exists, so deleted media can be undeleted.
5. **Secrets** (`OPENPOST_JWT_SECRET`, `OPENPOST_ENCRYPTION_KEY`, R2 keys) must be copied to the private off-box ops store. A database restore is useless without the same encryption key: OpenPost refuses or cannot decrypt provider tokens and admin overrides (Settings → Advanced → Configuration) if the key differs. The in-app ZIP backup (Settings → Instance → Backup) only works for SQLite plus *local* media, so it does not replace this procedure while media is on R2.

## Why one path per boot (blue-green promotes)

A Replit Reserved VM republish starts the new VM while the old one is still serving, and stops the old one only after the new one passes the health check. If both run Litestream against the same path, they write LTX files with the **same names** for **different** transactions and compact them into overlapping files. Litestream 0.5.18 has no writer lock (a lease type exists in the source but `replicate` does not use it), so nothing stops this. On 26 Nov 2026 this broke the legacy replica (see the incident below).

With a generation per boot the two VMs never share a path. Writes that reach the old VM after the new VM restored (normally under a minute during the promote) are not carried over; avoid admin changes while a republish is running.

## After a republish (automatic)

`scripts/amhar/start.sh` sees no local database and runs `scripts/amhar/restore.sh`:

1. List every generation under `$OPENPOST_LITESTREAM_GEN_ROOT/` plus the legacy path, and sort them by their newest object. The VM that is still serving writes every few seconds, so its path is newest. A generation's name alone is not enough: a boot that restored but was never promoted has a newer name and older data, and a VM still on the pre-generation `start.sh` writes to the legacy path.
   - Every R2 request has hard limits (`scripts/amhar/r2.sh`: connect 10 s, 30 s per list request, 2 retries, a pagination guard, an outer `timeout`) and logs one line, for example `r2: list backups/litestream-gen/…/: 350 entries, 1 page(s), 0s`. A stalled network shows up as `curl: (28) … timed out` and `could not list backups in R2 …; refusing to guess` (exit 1, fail closed).
   - The whole listing must fit in `OPENPOST_RESTORE_LIST_BUDGET_SECONDS` (default 150). Over budget, the boot fails closed rather than guess.
   - The listing is parsed with one `awk` per 1,000-key page. Before 27 Nov the parser forked about 16 processes per key (7.4 s per 1,000 keys on an 8-core box), which is what stalled the Reserved VM boot for over six minutes before `restore candidates` (see the incident below).
2. Restore the newest one with `litestream restore -integrity-check quick` (300 s timeout, 3 tries; progress is logged per attempt). If it fails, try the next one.
3. sqlite `.backup` snapshots are **never** picked automatically: they can be a day old, and the first one (26 Nov, 12:39 Baghdad) is an empty first-boot database. Use one only on purpose (see overrides).
4. Exit codes: `0` restored; `3` R2 has no backups at all (first boot, fresh database is fine); `1` backups exist but none restored.

On `1`, start.sh **exits with `FATAL: backups exist in R2 but none restored cleanly`**. The promote fails and the old VM keeps serving. It never starts an empty database on top of real backups. After any restore it picks a new generation id and runs `litestream replicate -exec openpost-server`, so Litestream does a final sync when Replit stops the VM.

## Check restores without changing anything

From the box or the Repl Shell, with the R2 variables loaded:

```sh
bash scripts/amhar/restore.sh --check
```

It restores every candidate into a temp folder, prints `OK` or `FAILED` and the user count for each, and ends with `check: a boot would restore from: …` (exit 0) or `check: a boot would FAIL CLOSED` (exit 1). Run it before every republish.

Two faster read-only checks use exactly the boot path's listing and order:

```sh
time bash scripts/amhar/restore.sh --list        # list and order only, no restore
time bash scripts/amhar/restore.sh --check-fast  # also restore the boot's pick into a temp folder
```

`--list` ends with `list: a boot would try <prefix> first`; `--check-fast` ends with `check-fast: a boot would restore from: …` or `FAIL CLOSED`. Neither writes to R2, the live database, or the generation file.

## Overrides (operator only)

| Variable | Effect |
| --- | --- |
| `OPENPOST_RESTORE_FROM=litestream:<prefix>` | Restore only from that replica path. |
| `OPENPOST_RESTORE_FROM=sqlite:<key>` | Restore only from that `.backup` object. |
| `OPENPOST_RESTORE_ALLOW_SNAPSHOT=true` | Let the automatic order fall back to `.backup` objects. |
| `OPENPOST_ALLOW_FRESH_DB=true` | Start empty even though backups exist. Data loss; never leave it set. |
| `OPENPOST_RESTORE_TIMEOUT_SECONDS` | Per-attempt Litestream restore timeout (default 300). |
| `OPENPOST_RESTORE_ATTEMPTS` | Litestream restore attempts per candidate (default 3). |
| `OPENPOST_RESTORE_LIST_BUDGET_SECONDS` | Total time allowed for the boot listing (default 150); over it, fail closed. |
| `R2_CONNECT_TIMEOUT`, `R2_LIST_MAX_TIME`, `R2_CURL_MAX_TIME`, `R2_CURL_RETRIES` | curl limits in `r2.sh` (10 s, 30 s, 300 s, 2). |
| `R2_IP_RESOLVE=4` | Force IPv4 for R2 requests (use only if logs show IPv6 connect timeouts). |
| `OPENPOST_BACKUP_FIRST_DELAY_SECONDS` | Delay before the first `.backup` (default 600). |

Remove an override from production Secrets as soon as the boot that needed it is live.

## Manual backup

```sh
bash scripts/amhar/backup.sh
```

## Manual restore (replaces the local database)

```sh
bash scripts/amhar/restore.sh --force
```

Then restart OpenPost and run `bash scripts/amhar/smoke.sh`.

## Local test of the boot path

`scripts/amhar/tests/r2-boot-list.sh` (under a minute, needs `rclone`, `curl`, `awk`; optional `LITESTREAM_BIN`, `python3`) checks the list parser against the old one, pagination, the boot order with 13 generations, the listing budget, a stalled endpoint, and that `--list` and `--check-fast` write nothing.

`scripts/amhar/tests/blue-green-local.sh` runs a throwaway S3 server (`rclone serve s3`), the real `start.sh`, and the pinned binaries as four "VMs". It checks first boot, a restore while the old VM keeps writing, the newest-generation pick, curl backups, and failing closed. It needs `rclone`, `curl` and `sqlite3`, and `AMHAR_TEST_BIN_DIR` pointing at the two pinned binaries. It takes about six minutes.

## Incident 27 Nov 2026: boot restore too slow for the promote window (times Baghdad)

- 14:09 a republish started. `start.sh` printed `no local database; restoring from R2` at 14:09:49 and then nothing for 6.5 minutes; `restore candidates` never printed. Replit stopped the VM at 14:16:27 and kept the old VM serving. The same happened on the retry.
- Cause: `r2_list` parsed each listed key with three `$(_r2_field …)` calls, each a subshell running `printf | grep | head` (about 16 forks per key). `list_candidates` lists every key of every generation and of the legacy path, a few thousand Litestream LTX files, so the boot spent minutes forking. The dev workspace has more CPU and finished `--check` in 3 min 58 s; the Reserved VM did not finish inside the window. curl also had no connect timeout and up to 4 × 300 s per call, so a network stall would have been just as silent.
- Fix (`fix/boot-restore-fast`): one `awk` per page (7.4 s → 0.02 s per 1,000 keys locally), hard timeouts and a progress line on every R2 call, a listing budget that fails closed, `--list` and `--check-fast`, and `tests/r2-boot-list.sh`.

## Incident 26 Nov 2026: broken legacy replica (times Baghdad)

- 15:10 republish `c4dcb5dc`. For about 10 s both VMs replicated to `backups/litestream`. The new VM wrote its boot snapshot as txid `1e2` (`0001/…01e2-…01e2.ltx`, 222 KB, all 897 pages). The old VM wrote its own `1e2`–`1e5`. The level-0 keys collided, and each VM compacted them into level 1: `01e2-01e2`, `01e2-01e5` and `01e3-01e5` overlap.
- From 15:15 every level-2 compaction fails: `non-contiguous transaction ids in input files: (…1e2,…1e5) -> (…1e3,…1e5)`. Every `litestream restore` of that path fails: `decode page 902: copy page 905 header: nonsequential page numbers in snapshot transaction: 901,905`. This was reproduced read-only from the box at any txid after `1e1`.
- 15:30 republish `bc572b2e`. Its restore failed as above. The fallback `python3 r2_sync.py` failed (`python3: command not found`; the image has no python3), so the old start.sh went on with an **empty** database. That VM did not answer on :8080 within the promote window (the exact reason is not in the logs we have), so Replit's health check saw 500s and the promote failed. OpenPost binds its port only at the end of startup, and Replit reports 500 while nothing listens. If it had passed, the live site would have been empty.
- The first `.backup` (`backups/sqlite/openpost-latest.db`, 12:39) has 0 users.
- The only clean copy was the live VM's local disk. The live VM's Litestream writes its next full snapshot to the legacy path at 00:00 UTC (03:00 Baghdad, 27 Nov). After that, a restore of the legacy path uses that snapshot plus single-writer files only. Confirm with `restore.sh --check` before republishing.

## Before every upgrade or republish

1. Run `bash scripts/amhar/restore.sh --check` and confirm `a boot would restore from:` with the expected user count.
2. Record the pinned release tag from `deploy/replit/pin.env`.
3. After the new publish comes up, confirm smoke and that a known workspace still exists (the restore worked).
4. Database migrations are not always reversible. A rollback needs the matching pre-upgrade snapshot plus the previous pinned binary.

## Health

```sh
bash scripts/amhar/health.sh
OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh
```

`/api/v1/health` means the process is up. `/api/v1/ready` must show the database (and storage, when reported) as ok.
