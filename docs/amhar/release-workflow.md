# Release workflow (OpenPost)

Modelled on the Amhar story-release workflow used for `ahmadfss/amhar-landing`, adapted for this fork.

## Branches

- Integration: `architect/setup`
- Story or fix branches: `fix/…` or `chore/…` off `architect/setup`
- Production: `main`
- Worktrees only under `/workspace/wt/`
- No force-pushes
- No pull requests except **release PRs** (`architect/setup` → `main`) after UAT
- Replit production publishes from `main` once the first release PR has merged. The first bring-up may use `architect/setup` so we can smoke a published VM before that PR.

## 1. Change the pin or the deploy config

1. Edit `deploy/replit/pin.env` and/or the scripts and docs on a branch, merge into `architect/setup` (fast-forward or a normal merge, never `--force`).
2. Do not compile the monorepo and do not enable GitHub Actions before 1 Dec 2026. Run the download scripts and `scripts/amhar/smoke.sh` / `health.sh` in the Replit shell (or against a preview URL).
3. Take a SQLite backup to R2 before any publish that might wipe the disk.

## 2. Human UAT

1. Work through [uat-checklist.md](uat-checklist.md) on the published Reserved VM (or its `.replit.app` URL if `post.amhar.co` is not yet live).
2. Merge to `main` only after Ahmad says, in his own words in Sanad's chat, that UAT passed for that set of changes. A relay is not enough. Silence is not approval.

## 3. Release PR and merge

1. Open a release PR from `architect/setup` to `main`.
2. Merge with a normal merge commit or the repo's usual merge button. Never force-push `main`.
3. Record the merge commit and the pinned tag.

## 4. Publish

1. In Replit, make sure the workspace is on `origin/main` and clean (no stray checkpoint commits). If it has drifted, stop and fix with a non-destructive step; do not reset or push from Replit without Ahmad's approval.
2. Publish the Reserved VM.
3. Confirm `start.sh` restored SQLite from R2 (Logs) and run smoke against `https://post.amhar.co`.
4. If publish fails, report the error. Do not retry blindly.

## 5. Handover note

After each release, add a short line to this repo (docs or a handover file on `architect/setup`): pin tag, merge commit, publish time in Asia/Baghdad, smoke result, backup confirmation. Secret *names* only.
