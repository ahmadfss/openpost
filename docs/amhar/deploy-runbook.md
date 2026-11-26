# Deploy runbook

Research and repo work can be done first. Publishing the Reserved VM spends $15/month from Pro credits and must wait for Ahmad's approval (already given on 26 Nov 2026 for the $15 VM, the fork, SQLite on the server, R2, and DNS).

Do not use the Replit Agent chat or "Fix with Agent". Use the Shell, Secrets, Publishing, and Domains panes.

## 1. Create the Repl from GitHub

1. In Ahmad's Replit account (the amhar.co / personal account, never 1001), create a new Repl by importing `https://github.com/ahmadfss/openpost`.
2. Import branch `architect/setup` for the first bring-up. After the first release PR is merged, the published app must track `main`.
3. Confirm `.replit` and `replit.nix` are present. Show hidden files if needed.
4. In the Shell, do **not** run `npm install`, `bun install`, or any monorepo build. The run/build scripts only download the pinned binaries.
5. Nix should pull `ffmpeg`, `sqlite`, `curl`, and `cacert`. If the `stable-25_05` channel is rejected, switch the channel in `.replit` in a follow-up commit rather than installing Node.

## 2. Secrets

Add these in **both** the workspace Secrets tool and the Publishing pane (production Secrets are separate):

- `OPENPOST_JWT_SECRET`
- `OPENPOST_ENCRYPTION_KEY`
- `OPENPOST_S3_ENDPOINT`
- `OPENPOST_S3_REGION` = `auto`
- `OPENPOST_S3_BUCKET`
- `OPENPOST_S3_ACCESS_KEY_ID`
- `OPENPOST_S3_SECRET_ACCESS_KEY`
- `OPENPOST_S3_PUBLIC_BASE_URL` = `https://media.post.amhar.co`
- `OPENPOST_APP_URL` = `https://post.amhar.co`
- `OPENPOST_PUBLIC_URL` = `https://post.amhar.co`
- `OPENPOST_MEDIA_URL` = `https://media.post.amhar.co`
- `OPENPOST_DISABLE_REGISTRATIONS` = `false` for the first boot, then `true` after the admin user exists

Optional: `OPENPOST_BACKUP_BUCKET` if backups use a second bucket; `OPENPOST_TRUSTED_PROXY_CIDRS` if scheme/IP forwarding is wrong behind the proxy.

Generate the two secrets with `openssl rand -base64 32` (twice). Keep the values in the private off-box backup store as well. Losing `OPENPOST_ENCRYPTION_KEY` makes connected social accounts unreadable.

## 3. Reserved VM publish settings

In Publishing:

1. Deployment type: **Reserved VM** (not Autoscale, not Static, not Scheduled). Autoscale would sleep and miss scheduled posts.
2. Machine: **shared 0.5 vCPU / 2 GB** at **$15/month**.
3. Build command: `bash scripts/amhar/build.sh` (already in `.replit`).
4. Run command: `bash scripts/amhar/start.sh` (already in `.replit`).
5. Port: local **8080**, external **80** (already in `.replit`). The process must listen on `0.0.0.0`, which the official binary does when `OPENPOST_PORT` is set.
6. Confirm production Secrets are present, then publish.

First publish will download the 511 MB binary during **build**. The subsequent health check should see a running server. If the health check times out, check Logs: missing secrets, R2 errors, or ffmpeg missing are the usual causes.

## 4. Custom domain `post.amhar.co` (do not guess records)

Replit, not Cloudflare, decides the exact DNS values. Do **not** create `post.amhar.co` in Cloudflare until the Replit Domains tool has printed the records.

Prepared steps:

1. In the Replit project, open **Tools → Domains**.
2. Connect a domain you already own: `post.amhar.co`.
3. Skip Entri guided login to Cloudflare if you are adding records by hand.
4. Copy the records Replit shows. They are:
   - an **A** record on hostname `post` in the `amhar.co` zone, value exactly as Replit prints it (no trailing dot unless Replit includes one);
   - a **TXT** record on hostname `post`, value `replit-verify=...` exactly as printed.
5. Add both at the same time in the amhar.co Cloudflare DNS (DNS only / grey cloud is the usual choice so Replit can issue and renew TLS). The TXT record is permanent; deleting it later will break certificate renewal.
6. Wait until the Domains tool shows Verified, then load `https://post.amhar.co/api/v1/ready`.

`media.post.amhar.co` is not a Replit domain. It is the R2 public custom domain for the media bucket.

## 5. First boot

1. Open `https://post.amhar.co` (or the `.replit.app` URL if DNS is not yet live).
2. Create the first account; it becomes the instance administrator.
3. Set `OPENPOST_DISABLE_REGISTRATIONS=true` in production Secrets and republish, or restart if Replit picks up the new value without a full republish. **A republish wipes the local SQLite file.** Confirm `scripts/amhar/start.sh` restored the database from R2 before considering the app live. If this is the first boot and no backup has been taken yet, take one (`bash scripts/amhar/backup.sh`) *before* any republish.
4. Run `OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh`.
5. Hand over to Badee3 using [handover-badee3.md](handover-badee3.md).

## 6. What not to do

- Do not merge to `main` except through a release PR after Ahmad's UAT.
- Do not force-push.
- Do not enable GitHub Actions before 1 Dec 2026.
- Do not store secrets in the repo, in `.env` committed to git, or in chat.
- Do not use 1001 accounts.
