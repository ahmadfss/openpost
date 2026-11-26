# Amhar OpenPost

Amhar runs a self-hosted [OpenPost](https://github.com/getopenpost/openpost) instance so Badee3 can schedule social posts (X, LinkedIn, Facebook, Instagram, YouTube Shorts) from the web UI and through MCP.

This fork does not rebuild OpenPost. Replit downloads the pinned upstream linux-amd64 release (`v7.42.5` at first deploy), verifies its size and SHA-256, installs ffmpeg, and runs the single binary. The database is SQLite on the Reserved VM, with continuous Litestream replication and a nightly snapshot to Cloudflare R2.

| Document | Contents |
| --- | --- |
| [architecture.md](architecture.md) | Process, storage, DNS, what happens on a republish |
| [env-and-secrets.md](env-and-secrets.md) | Environment variable and secret *names* only |
| [deploy-runbook.md](deploy-runbook.md) | Create the Repl, Reserved VM, secrets, custom domain |
| [backup-and-restore.md](backup-and-restore.md) | Litestream, nightly snapshots, restore after a wipe |
| [cost-notes.md](cost-notes.md) | Expected monthly cost |
| [release-workflow.md](release-workflow.md) | Branches, UAT, release PRs, publish |
| [uat-checklist.md](uat-checklist.md) | Checks before handover |
| [handover-badee3.md](handover-badee3.md) | OAuth callbacks, MCP tokens, known limits |

Scripts live in `scripts/amhar/`. Pin values live in `deploy/replit/pin.env`.
