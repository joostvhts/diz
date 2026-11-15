# Security

## Reporting a vulnerability

Report security problems privately: open this repository's **Security** tab and
choose **Report a vulnerability**. Only the maintainer sees it. Please don't
open a public issue for a security problem.

Diz is a hobby project with one maintainer. Expect a first reply within about a
week. Fixes ship in the next release.

## Supported versions

Only the latest release gets fixes. See the
[releases page](https://github.com/joostvhts/diz/releases).

## Scope

In scope:

- **diz-bridge's HTTP API.** The bearer-token check on `/api`, how the token is
  read (`DIZ_API_TOKEN` or `DIZ_API_TOKEN_FILE`), anything that lets a request
  without the token control lights or read their state, and anything that
  crashes the bridge over the network.
- **The Diz app.** How it stores the bridge address and token, and how it
  connects. Release builds only connect over HTTPS.
- **The Docker image and the systemd package.** Running as a non-root user, file
  permissions, and which ports they open.

Out of scope:

- **The WiZ local protocol itself.** WiZ bulbs accept commands over UDP from any
  device on the same network, without authentication. That's how the bulbs
  work, with or without Diz. Keep untrusted devices off that network.
- **`/healthz`.** It's open on purpose and only returns `{"status":"ok"}`.
- **A reverse proxy or VPN in front of the bridge.** Report those problems to
  their own projects.
