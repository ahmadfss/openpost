# Handover for Badee3

OpenPost will be at `https://post.amhar.co` once DNS and the Reserved VM are live. You own the network developer apps and the daily posting routines through OpenPost's MCP. Sanad owns the Replit VM, the SQLite backups, and R2.

Use an `amhar.co` or Ahmad's personal Google/GitHub account. Never a 1001 account.

## Before connecting any network

`OPENPOST_APP_URL` must already be `https://post.amhar.co`. Changing it later means updating every provider portal and reconnecting accounts.

## Callback URLs

Register these exact redirect URIs (scheme, host, path, no extra slash):

| Network | Redirect URI |
| --- | --- |
| X | `https://post.amhar.co/api/v1/accounts/x/callback` |
| LinkedIn | `https://post.amhar.co/api/v1/accounts/linkedin/callback` |
| Facebook | `https://post.amhar.co/api/v1/accounts/facebook/callback` |
| Instagram | `https://post.amhar.co/api/v1/accounts/instagram/callback` |
| YouTube | `https://post.amhar.co/api/v1/accounts/youtube/callback` |

X needs an OAuth 1.0a app with write access (the API Key pair, not OAuth 2.0-only credentials). LinkedIn company-page posting needs Community Management API access (LinkedIn review) and `OPENPOST_LINKEDIN_ORGANIZATIONS_ENABLED=true` on the VM. Facebook and Instagram can share one Meta app, but Instagram still needs its own redirect URI and a professional account; the Instagram login will not work while `@amhar_academy` is signed out. YouTube uses a Google OAuth web client.

Save credentials in Settings → Instance → Configuration → Provider apps as instance admin, then restart OpenPost if the UI asks you to. Then connect each workspace account under Settings → Workspace → Social accounts.

OpenPost will not schedule for a network until that network passes live checks against the provider at schedule time. A successful sign-in is not the same as a successful test post. After connecting, publish one small test post per network and confirm it on the network itself.

YouTube Community posts cannot be automated; the YouTube API does not allow it. Keep those manual.

## MCP

Endpoints (same auth either way):

- `https://post.amhar.co/mcp` — one tool per operation (default)
- `https://post.amhar.co/mcp/code` — compact tools, better for clients with a small tool limit

Authentication is required. Either:

1. Browser OAuth (the client uses `/.well-known/` discovery on `https://post.amhar.co`), or
2. A developer token from Settings → Personal → Developer, stored only in the client's secret store, never in a chat or a committed file.

Scopes: `mcp:read` (inspect only) or `mcp:full` (create, schedule, publish). An OAuth request with no scope defaults to `mcp:full`. Bind the token to the Amhar workspace so it cannot see any other workspace.

Ask the assistant to list workspaces and then to create an unpublished draft for review before you let it schedule or publish. Recent MCP calls appear under Settings → Personal → Developer access.

The 19 Nov test found that OpenPost accepts a plain developer token, which is the easier path for routines. The web UI is English only; Arabic post text displays right-to-left. Prefer MCP or the API over the CLI, which garbled Arabic in listings during that test.

## Moving routines

Move one platform at a time. Keep the existing browser posting path as the fallback until that platform's test post has succeeded. Sanad can restart the VM or restore SQLite; you should not need to touch Replit Secrets or R2 keys.
