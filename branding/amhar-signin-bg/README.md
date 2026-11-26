# Amhar sign-in background

Artwork for the public OpenPost auth pages on `post.amhar.co`.

The Reserved VM runs a pinned upstream OpenPost binary with an embedded
frontend, so this directory is not compiled into that binary. Nginx (see
`scripts/amhar/signin-bg-overlay.sh`) serves these files at `/amhar-signin-bg/`
and injects `auth.css` plus `auth.js` into HTML responses. The script turns the
artwork on only for `/login`, `/register`, `/forgot-password`, and
`/reset-password`.

| File | Role |
| --- | --- |
| `option-f-riverside-morning.webp` | Primary 1920×1080 background (under 500 KB) |
| `option-f-riverside-morning.jpg` | Fallback for browsers without WebP |
| `wordmark-colour-tight.webp` | Mobile overlay; cover+center crops the in-image أمهر |
| `auth.css` | Cover/center background, card contrast, mobile wordmark |
| `auth.js` | Adds `html.amhar-auth-bg` on auth routes only |

Master PNG (not committed here): `amhar-marketing/post-amhar-signin-bg/finals/option-f-riverside-morning.png`.

Disable the overlay with `OPENPOST_SIGNIN_BG_OVERLAY=0` and republish.
