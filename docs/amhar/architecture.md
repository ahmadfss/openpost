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


## Sign-in background overlay

The pinned upstream binary embeds the OpenPost frontend, including the public
auth pages. This fork does not rebuild that frontend. A small nginx sidecar
(`pkgs.nginx` in `replit.nix`) listens on the public port (8080), serves
`branding/amhar-signin-bg/` at `/amhar-signin-bg/`, injects a stylesheet and
script into HTML responses, and proxies everything else to OpenPost on
`127.0.0.1:18080`. The script enables the artwork only on `/login`,
`/register`, `/forgot-password`, and `/reset-password`.

On boot, `scripts/amhar/start.sh` appends `127.0.0.1/32,::1/128` to
`OPENPOST_TRUSTED_PROXY_CIDRS` so session CSRF still sees Replit's forwarded
`Origin` / `X-Forwarded-*` headers through the extra hop. Existing CIDRs are
kept. Disable the overlay with `OPENPOST_SIGNIN_BG_OVERLAY=0` (then republish).

When the overlay is on, OpenPost logs `http server started on [::]:18080`, not
`:8080`. The Replit health check and `https://post.amhar.co` still hit nginx
on 8080.
