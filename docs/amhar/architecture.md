# Architecture

```
Badee3 / MCP clients
        |  HTTPS
        v
  post.amhar.co   (Cloudflare DNS; TLS issued by Replit)
        |
        v
  Replit Reserved VM  (always on, shared 0.5 vCPU / 2 GB)
    openpost-server (pinned upstream linux-amd64 binary)
    ffmpeg / ffprobe
    Litestream (replicate SQLite to R2)
    nightly sqlite3 .backup upload to R2
        |
        +-- SQLite at $HOME/openpost-data/db/openpost.db
        +-- Cloudflare R2: media at media.post.amhar.co
        +-- Cloudflare R2: backups (bucket or prefix)
```

One Go process serves the web UI, the API, and background jobs. Redis is not used. A separate worker is not used.

## Persistence (important)

Replit's own docs state that the filesystem in published apps is **not persistent and resets every time you publish**. A Reserved VM keeps the disk across ordinary process restarts, but a republish or VM recreation wipes local files, including SQLite.

So SQLite on the VM is the live database, and R2 is the durable copy:

1. Litestream replicates the database continuously and takes a 24h snapshot.
2. A loop takes a consistent `sqlite3 .backup` shortly after boot and then every 24 hours, stored as `backups/sqlite/openpost-latest.db` plus a dated object.
3. `scripts/amhar/start.sh` restores from R2 when the local database file is missing, then starts OpenPost.

Media is stored only on R2, so a republish does not delete posts' images or videos.

## Build vs run

The Replit build command (`scripts/amhar/build.sh`) only downloads and verifies the pinned OpenPost and Litestream binaries. It does not compile the monorepo or run `bun`/`npm`. The run command starts the already-downloaded binary so the publish health check is not blocked by a 511 MB download.
