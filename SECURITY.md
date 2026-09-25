# Security

## Supported versions

The latest release, and `main` between releases. Older tags receive no fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: <https://github.com/selimacerbas/markdown-preview.nvim/security/advisories/new>. Do not open a public issue for a security problem.

You get a reply within seven days. A confirmed report is fixed in a release and credited in the advisory unless you ask otherwise.

## What the preview server exposes

The preview server is live-server.nvim's, and its per-session 128-bit token is the boundary. Five surfaces require the token: the content file (`content.md`), the `asset_root` sidecar that names the source file's directory, the event stream (`/__live/events`), the inject endpoint (`/__live/inject`) and the asset route (`/__live/asset`), which serves any file at or below the source file's directory. On the loopback default the index page is not gated and carries the token itself (its `data-live-token` attribute), so the token keeps out what cannot reach the port, and not another local user or a page that reads the preview page as its own origin. On a network bind the index page is gated too and carries no token; the browser takes it from the `?t=` query of the URL the plugin opens, so the token is what a peer without that URL lacks. The preview page loads its renderer and plugins from public CDNs (`assets/index.html` names each), several at floating major versions and none with an integrity hash, so a script served there runs in the page that holds the token. Raw HTML in a previewed file runs inside the preview page; `allow_raw_html = false` is meant to stop it and is being hardened, so a report that shows HTML running with it off is in scope. A report about either of those documented choices is still welcome when it shows a way around the token or the containment.
