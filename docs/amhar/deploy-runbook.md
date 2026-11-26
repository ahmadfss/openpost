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

## 4. If publish dies at "Installing packages"

A first Reserved VM publish of this branch failed at the **Installing packages** stage with `no such language: bash`. Build and Bundle never ran.

The original `.replit` set top-level `language = "bash"` and `[packager] language = "bash"`. Replit's package installer uses those keys to pick a language packager ([`.replit` configuration](https://docs.replit.com/features/project-setup/configuration), [dependency management](https://docs.replit.com/features/project-setup/dependency-management)). Bash is not a supported packager language, so the publish stopped there. Setting `[packager.features] enabledForHosting = false` did not skip the step.

The fix is already in `.replit` on this branch:

- Remove the top-level `language` key and the whole `[packager]` / `[packager.features]` sections, so the deploy uses only the Nix deps from `replit.nix`.
- Keep `[nix]`, `run`, `entrypoint`, `[[ports]]`, and `[env]`.
- Under `[deployment]`, set `deploymentTarget = "gce"` for Reserved VM. Official docs exemplify `cloudrun` on the configuration page; Reserved VM publishes use `gce` (choose Reserved VM in Publishing as well — see [deployment types](https://docs.replit.com/features/publishing/deployment-types)).
- Do not add a `modules` line. Modules are language/runtime packager bundles such as `nodejs-20` or `python-3.10`. There is no documented bash module, and a language module would pull a packager we do not want. Do not work around this with Node or Bun.

After pulling this change into the Repl, republish. Do not run `npm install` or `bun install`.

## 5. Custom domain `post.amhar.co` (do not guess records)

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

## 6. First boot

1. Open `https://post.amhar.co` (or the `.replit.app` URL if DNS is not yet live).
2. Create the first account; it becomes the instance administrator.
3. Set `OPENPOST_DISABLE_REGISTRATIONS=true` in production Secrets and republish. **A republish wipes the local SQLite file** and restores it from R2. Before any republish run `bash scripts/amhar/restore.sh --check` and confirm `a boot would restore from: …` with the expected user count (see [backup-and-restore.md](backup-and-restore.md)). After the republish, confirm the log shows `database restored to` and the expected `users in restored database`.
4. Run `OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh`.
5. Hand over to Badee3 using [handover-badee3.md](handover-badee3.md).

## 6a. "cross-site session request rejected" (403) behind Replit's proxy

Symptom: sign-in works, but every cookie-authenticated POST (for example creating the first workspace on `/onboarding`) returns 403 `cross-site session request rejected`.

Cause: the session CSRF check compared the browser `Origin` (`https://post.amhar.co`) with the scheme and Host the Go process sees. `UseTrustedProxies` deletes `X-Forwarded-Proto` unless the direct peer is inside `OPENPOST_TRUSTED_PROXY_CIDRS` (unset here), and it also dropped list values such as `https,http`. So the process saw `http` and the check failed.

Fix (commit on `architect/setup`, `apps/server/internal/api/middleware/session_origin.go`):

- The server builds a trusted-origins list from `OPENPOST_APP_URL` and `OPENPOST_PUBLIC_URL` (scheme + host only). An `Origin` exactly equal to one of them passes, whatever Host or proto the proxy forwards.
- Otherwise the `Origin` must match the first `X-Forwarded-Proto` value (or TLS) plus `X-Forwarded-Host` or `Host`. Any other origin is still rejected, and a POST without an `Origin` is still rejected.
- The trusted-proxy middleware now keeps the first value of a comma-separated `X-Forwarded-Proto`.

**This is a source change.** The Reserved VM runs the pinned upstream binary (`deploy/replit/pin.env`, `scripts/amhar/build.sh` only downloads it), so a plain republish does not pick it up. Until a binary built from this branch is pinned, the config-only workaround is to set `OPENPOST_TRUSTED_PROXY_CIDRS` to the CIDR of Replit's proxy peer (read `remote_ip` in the request log; do not guess) and republish.

## 6b. Republish safety: Litestream generations and failing closed

Background: [backup-and-restore.md](backup-and-restore.md), incident of 26 Nov 2026. A Replit promote runs the old and new VMs at the same time, so each boot now replicates to its own path (`backups/litestream-gen/<generation>`). A boot that finds backups but cannot restore any of them stops with `FATAL: backups exist in R2 but none restored cleanly`, and the old VM keeps serving.

Every republish:

1. Run `bash scripts/amhar/restore.sh --check` (box or Repl Shell, R2 variables loaded). It must end with `check: a boot would restore from: litestream …` and show the expected `users in restored database`. If it says `FAIL CLOSED`, do not republish.
2. Avoid admin changes while the promote runs. Writes to the old VM after the new VM restored are not carried over.
3. Republish. In the deployment logs look for, in order:
   - `restore candidates (newest first):`
   - `OK: litestream <prefix>` and `users in restored database: <n>`
   - `database restored to …`
   - `litestream generation <id> -> backups/litestream-gen/<id>`
   - `signin-bg overlay: nginx will listen on 0.0.0.0:8080; openpost on 127.0.0.1:18080`
   - `http server started on [::]:18080` (OpenPost binds the internal port; nginx is on 8080)
4. Smoke: `OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh`, sign in, and check the workspace and members.
5. Run `restore.sh --check` again. It should now pick `backups/litestream-gen/<new id>`.
6. About ten minutes after boot, the log shows `backup uploaded: backups/sqlite/<id>/openpost-….db and backups/sqlite/openpost-latest.db (…, <n> users)`.

The deploy image has no python3. Deploy scripts use bash, curl (`--aws-sigv4`, `scripts/amhar/r2.sh`), `sqlite3`, coreutils, sed, grep and awk from `replit.nix`. Do not add python back to the boot path.

## 7. What not to do

- Do not merge to `main` except through a release PR after Ahmad's UAT.
- Do not force-push.
- Do not enable GitHub Actions before 1 Dec 2026.
- Do not store secrets in the repo, in `.env` committed to git, or in chat.
- Do not use 1001 accounts.
