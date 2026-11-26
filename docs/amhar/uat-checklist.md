# UAT checklist

Use this before asking Ahmad for UAT OK and before handing the instance to Badee3. Mark each item pass, fail, or blocked.

## Instance

- [ ] `https://post.amhar.co/api/v1/health` responds (or the `.replit.app` URL if DNS is not yet live).
- [ ] `https://post.amhar.co/api/v1/ready` shows the process ready, with the database ok and storage ok.
- [ ] `OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh` exits 0.
- [ ] The first account can sign in and is the instance administrator.
- [ ] After that account exists, registrations are closed (`OPENPOST_DISABLE_REGISTRATIONS=true`) and a second uninvited signup is rejected.
- [ ] ffmpeg is on PATH in the VM (`ffmpeg -version` and `ffprobe -version`).

## Media and database

- [ ] A test image uploads and is publicly fetchable at a `https://media.post.amhar.co/…` URL without signing in.
- [ ] A short test video uploads, ffmpeg verify/poster succeeds, and the public URL is fetchable.
- [ ] `bash scripts/amhar/backup.sh` uploads `openpost-latest.db`.
- [ ] Idle-and-restore drill: stop the app, move or delete the local SQLite file, start again, and confirm `start.sh` restores the workspace from R2. (On a Reserved VM, a full republish is the real-world version of this drill; do it only after a confirmed backup.)

## Scheduling and MCP (can wait for Badee3's OAuth)

- [ ] MCP at `https://post.amhar.co/mcp` rejects an unauthenticated request.
- [ ] A workspace-bound developer token with `mcp:full` can list workspaces.
- [ ] After each network's OAuth app is connected and passes live checks: one test post per network (X, LinkedIn Page, Facebook Page, Instagram, YouTube Shorts).
- [ ] A scheduled post still fires after the VM has been idle for at least 10 minutes (the process stays up on a Reserved VM).

## Known limits to confirm, not to "fix" in UAT

- The web UI is English only. Arabic post text should display right-to-left.
- YouTube Community posts cannot be published through the API.
- OpenPost will not schedule a network until that network passes its live checks.
- The CLI may garble Arabic in listings; use MCP or the API instead.
