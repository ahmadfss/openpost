# Cost notes

Figures checked 26 Nov 2026 (Asia/Baghdad).

| Line | Estimate |
| --- | --- |
| Replit Reserved VM, shared 0.5 vCPU / 2 GB | $15 / month, taken from Pro credits first |
| Neon | Not used. SQLite is on the VM. |
| Cloudflare R2, Standard, inside the free tier (10 GB-month, 1M Class A, 10M Class B, unlimited egress) | $0 |
| Redis | $0, not used |
| DNS on the existing amhar.co Cloudflare zone | $0 |
| **Expected cash cost** | **$15 / month**, unless Pro credits are already exhausted |

R2 must have a payment method on the Cloudflare account even when usage stays at $0. There is no hard spend cap; stay on Standard storage and watch the dashboard. Do not turn on Infrequent Access (it is not covered by the free tier).

If 2 GB is too tight once ffmpeg is transcoding, the next size is a dedicated 1 vCPU / 4 GB Reserved VM at $35 / month. That is a later, paid approval.

GitHub Actions on this fork are disabled (standing rule: no Actions until 1 Dec 2026). Smoke and health checks run as scripts in the Replit shell.
