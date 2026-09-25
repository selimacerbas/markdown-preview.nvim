# Security

## Supported versions

The latest release, and `main` between releases. Older tags receive no fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: <https://github.com/selimacerbas/markdown-preview.nvim/security/advisories/new>. Do not open a public issue for a security problem.

You get a reply within seven days. A confirmed report is fixed in a release and credited in the advisory unless you ask otherwise.

## What the preview server exposes

The preview binds to `127.0.0.1` by default and gates the buffer content, the event stream and the asset route behind a per-session token. Binding to a network address is an explicit choice, and the README's Security section describes what a peer holding the URL can read. Raw HTML in a previewed file runs inside the preview page; `allow_raw_html = false` is meant to stop it and is being hardened, so a report that shows HTML running with it off is in scope. A report about either of those documented choices is still welcome when it shows a way around the token or the containment.
