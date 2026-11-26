# Environment variables and secrets (names only)

Put values in the Replit **published-app** Secrets pane, not in this repository and not only in the workspace Secrets (those do not automatically carry over to a published Reserved VM).

Never commit values. Never paste tokens into chat or screenshots.

## Required secrets

| Name | Purpose |
| --- | --- |
| `OPENPOST_JWT_SECRET` | Session/JWT signing. Generate with `openssl rand -base64 32`. Keep stable. |
| `OPENPOST_ENCRYPTION_KEY` | Encrypts stored provider tokens. Generate separately. Losing it makes connected accounts unreadable. |
| `OPENPOST_S3_ENDPOINT` | `https://<accountid>.r2.cloudflarestorage.com` |
| `OPENPOST_S3_REGION` | `auto` |
| `OPENPOST_S3_BUCKET` | Media bucket, e.g. `openpost-media` |
| `OPENPOST_S3_ACCESS_KEY_ID` | R2 API token access key |
| `OPENPOST_S3_SECRET_ACCESS_KEY` | R2 API token secret |
| `OPENPOST_S3_PUBLIC_BASE_URL` | `https://media.post.amhar.co` |

## Public URLs and runtime (non-secret, but set them)

| Name | Value |
| --- | --- |
| `OPENPOST_APP_URL` | `https://post.amhar.co` |
| `OPENPOST_PUBLIC_URL` | `https://post.amhar.co` |
| `OPENPOST_MEDIA_URL` | `https://media.post.amhar.co` |
| `OPENPOST_PORT` | Set if you need to override; `start.sh` copies Replit's `PORT` or defaults to `8080`. The binary ignores `$PORT` unless this is set. |
| `OPENPOST_EDITION` | `selfhost` (also in `.replit`) |
| `OPENPOST_DATABASE_DRIVER` | `sqlite` |
| `OPENPOST_DATABASE_PATH` | Default `$HOME/openpost-data/db/openpost.db` |
| `OPENPOST_STORAGE_DRIVER` | `s3` |
| `TZ` | `Asia/Baghdad` |
| `OPENPOST_DISABLE_REGISTRATIONS` | `false` until the first admin exists, then `true`. An admin override saved in Settings → Advanced → Configuration is stored encrypted in SQLite and applied after the environment at startup, so the override wins. Keep the secret `true` as well, so a database restored without the override is still closed. |
| `OPENPOST_TRUSTED_PROXY_CIDRS` | Set once TLS is terminated in front of the process, if callbacks or scheme detection mis-fire |
| `OPENPOST_TELEMETRY_ENABLED` | `false` |
| `OPENPOST_WORKFLOWS_AI_ENABLED` | `false` until an AI key is explicitly approved |
| `OPENPOST_EMAIL_VERIFICATION_REQUIRED` | `false` until email is configured |
| `OPENPOST_MCP_MODE` | `direct` (optional) |
| `OPENPOST_LINKEDIN_ORGANIZATIONS_ENABLED` | `true` when the LinkedIn Page app is ready |

## Backup-only (optional; defaults are fine)

| Name | Default |
| --- | --- |
| `OPENPOST_BACKUP_BUCKET` | Same as `OPENPOST_S3_BUCKET` if unset |
| `OPENPOST_BACKUP_PREFIX` | `backups/sqlite` |
| `OPENPOST_LITESTREAM_PREFIX` | `backups/litestream` (legacy path, read-only for restore) |
| `OPENPOST_LITESTREAM_GEN_ROOT` | `backups/litestream-gen` (one replica path per boot) |
| `OPENPOST_DATA_DIR` | `$HOME/openpost-data` |

Restore overrides (`OPENPOST_RESTORE_FROM`, `OPENPOST_RESTORE_ALLOW_SNAPSHOT`, `OPENPOST_ALLOW_FRESH_DB`, timeouts) are listed in [backup-and-restore.md](backup-and-restore.md#overrides-operator-only). Leave them unset in normal operation.

Litestream and the backup script also accept `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, and `AWS_REGION`. `start.sh` copies the `OPENPOST_S3_*` names into those if the AWS names are empty, so one key pair is enough when media and backups share the same credentials.

## Provider apps

Prefer Settings → Instance → Configuration → Provider apps (encrypted in SQLite). Alternatively `OPENPOST_PROVIDER_APPS` as one JSON array. Environment values win and become read-only in the UI.

## Accounts

Use `ahmad@amhar.co` or Ahmad's personal Gmail. Never a 1001 address, inbox, or account.
