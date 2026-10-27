# Renga

Renga reaches PostgreSQL through `tmp/postgres-socket`, with no database TCP
port. On native Linux, `make up` starts the container from `docker-compose.yml`;
on macOS, where Docker Desktop cannot forward a container socket to the host,
it starts a native cluster from the Nix development shell instead. Run
`make down` to stop PostgreSQL and `make db` to open a `psql` console.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4401`](http://localhost:4401) from your browser.

The Nix flake provides the toolchain: `nix develop` (or `direnv allow`) gives
you Elixir, Rust, PostgreSQL, Node.js, and the Playwright browsers.

## Tests

Run `mix test` for the whole suite, or `mix precommit` before committing.

Browser tests live in `test/renga_web/browser`, are tagged `:playwright`, and
drive Chromium through [PhoenixTest.Playwright][ptp]. Use them for behavior
that only a real browser shows, such as layout, density, focus, or touch
targets. They need:

* the Playwright npm package, installed into `assets/node_modules` by
  `mix setup` (or `mix assets.setup`);
* browsers matching that package. Inside the Nix shell these come from
  nixpkgs, so `assets/package.json` must pin the same Playwright version as
  nixpkgs' `playwright-driver`; the shell warns when they differ. Outside Nix,
  run `npm exec --prefix assets -- playwright install chromium`.

Without Playwright, `mix test` skips the browser tests, except in CI, where it
fails. The test helper rebuilds the CSS and JS bundles first, so browser tests
never run against stale assets. Set `PW_TRACE=true` or `PW_SCREENSHOT=true` to
keep a trace or screenshot of each failing browser test under `tmp/`; open a
trace with `npm exec --prefix assets -- playwright show-trace <file>`.

When updating the `nixpkgs` flake input, bump `playwright` in
`assets/package.json` to the new `playwright-driver` version and run
`npm install --prefix assets` to refresh the lockfile.

[ptp]: https://hexdocs.pm/phoenix_test_playwright

## Amp orb development

Run `amp orb services ensure` in an Amp orb to start the supervised Phoenix
server and print its authenticated portal URL. `mix setup` seeds a development
workspace with representative inventory:

* Email: `demo@renga.local`
* Password: `supersecure!`
* Organization: `Renga Labs`

The orb lifecycle also creates an ignored, disposable Git repository at
`dev/agent-target`. It can be deleted at any time; `.agents/setup` or
`.agents/resume` recreates it for coding-agent experiments.

The real Rust host agent also runs as the supervised `renga-agent` orb service.
Its generated development credential, configuration, installation identity,
and state live under the ignored `dev/renga-agent` directory. The collector
checks in every 10 seconds and reports inventory every minute, so it appears in
the authenticated **Collectors** screen without manual enrollment.

## Design proposals

Product and architecture decisions live in Requests for Discussion (RFDs) in
[renga-dcim/RFD](https://github.com/renga-dcim/RFD), which also publishes them
as a site. Code and comments cite them by number, such as "RFD 8".

## Running in production

The `Dockerfile` builds the Phoenix server as an OTP release. Configure its
runtime server and database settings with environment variables:

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | yes | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | yes | Generate with `mix phx.gen.secret` |
| `PHX_HOST` | yes | Public host name used in generated URLs, and the home agents are sent to (RFD 23) |
| `DATABASE_SSL` | no | `true` to require TLS, verifying the server certificate against the OS trust store and the URL's host name; any `ssl` query option in `DATABASE_URL` must also be `true` |
| `POOL_SIZE` | no | Database connections per node (default 10) |
| `DATABASE_STATEMENT_TIMEOUT` | no | Longest a single application statement may run, in milliseconds (default 30000), so one organization's slow query cannot hold a connection others need (RFD 21). It is sent as a connection startup parameter, so a PgBouncer in front of the database must accept `statement_timeout` (do not list it in `ignore_startup_parameters`, which would drop the bound). `bin/migrate` runs without it |
| `DATABASE_BACKGROUND_STATEMENT_TIMEOUT` | no | Longer per-statement limit for approved background work such as job history purges, in milliseconds (default 300000) |
| `ECTO_IPV6` | no | `true` to reach the database over IPv6 |
| `DNS_CLUSTER_QUERY` | no | DNS name that resolves to every node, for clustering |
| `PORT` | no | HTTP port (default 4000) |
| `DEPLOYMENT_ID` | no | A short, non-secret name for this deployment, such as `eu1`: at most 16 lowercase letters, digits, and hyphens. New intake keys carry it so a resolver can route agents here (RFD 23); existing keys keep working |
| `OPERATOR_PORT` | no | Serve the operator API (RFD 22) on this port, over HTTPS, separately from `PORT`, from which it must differ. Unset, there is no operator listener. It starts with the web server (`bin/server`, which sets `PHX_SERVER`), and reads its TLS settings at startup, so restart to change them |
| `OPERATOR_TLS_CERTFILE`, `OPERATOR_TLS_KEYFILE` | with `OPERATOR_PORT` | PEM certificate chain and key the operator listener serves |
| `OPERATOR_IP` | no | Address the operator listener binds to (default: all interfaces, like `PORT`). Binding to a private address is not an access boundary by itself |
| `OPERATOR_CLIENT_CA_FILE` | no | PEM certificate authority for mutual TLS: the listener completes a handshake only with a client certificate it issued. Recommended whenever the port is reachable from the internet |
| `OPERATOR_CLIENT_CRL_FILE` | no | PEM revocation lists for every authority in client certificate chains, the root's and any intermediate's, checked on every handshake. A chain missing a current list is refused. Read at startup, so restart to pick up new lists before they expire |

Run `/app/bin/migrate` once per deploy, before new nodes start, then run
`/app/bin/server`.

Operator tasks run on the server with `/app/bin/renga-admin`, like
`bin/providers`: it starts the database connection but not the web server, and
reads the same environment as the server. `renga-admin operator-tokens create
--actor NAME --name NAME --scopes SCOPE,...` creates a token for the operator
API (RFD 22) and prints it once; `list` and `revoke ID_OR_NAME --actor NAME`
manage existing tokens. Every change names its `--actor` and is recorded,
whether it succeeds or is refused, in the `deployment_audit_events` table with
an invocation ID, never with a token.

`renga-admin organizations suspend|resume|schedule-deletion|cancel-deletion
--organization SLUG --actor NAME` contains or recovers a tenant using the same
audited transitions as the operator API's `/operator/v1/organizations/:id/`
`suspend`, `resume`, `schedule-deletion`, and `cancel-deletion` POST operations.
These target-state operations can be retried without extending a deletion
deadline. Suspension blocks tenant access and new agent work, cancels queued
jobs, and withdraws running leases without claiming execution succeeded.
Scheduling deletion immediately suspends access and starts a 30-day grace
period; current owners can export or cancel from `/organizations/deletions`.
Cancellation restores access; resume also cancels pending deletion. Neither
reruns cancelled work. Once purge starts, neither operation can undo it. The
worker retries interrupted purges; shared users and deployment audit attribution
survive tenant deletion. Owner notifications are durably queued for delivery.

`renga-admin limits set --organization
SLUG --actor NAME --job-creation-rate N` overrides a limit for one
organization (RFD 21) and records the change in its Activity too,
`limits show` lists them, and `limits clear` returns one to the deployment
default, which `LIMIT_*` variables such as `LIMIT_JOB_CREATION_RATE` set.
Owners see their limits and usage under Settings > Limits. `renga-admin
export --organization SLUG --output FILE --actor NAME` writes one
organization's export archive (RFD 20, [format](docs/export-format.md)) from a
consistent snapshot; `--history` and `--raw-observations` add the optional
parts. The file is created readable only by its owner and holds no
credentials, but it holds all of the organization's data. `renga-admin import
--organization SLUG --input FILE --owner EMAIL --actor NAME` validates an
archive and imports it, whole or not at all, into an organization that is
still empty apart from its owner, who then invites people back.
Records keep their IDs, so the original organization must be gone from the
deployment. People arrive as principals rather than accounts, keys and
bindings must be approved again, and imported jobs never run. Run
`renga-admin` with no arguments for usage, or `mix renga.admin` in
development.

Put the server behind a TLS-terminating reverse proxy; the
container listens for HTTP on `PORT`. `DATABASE_SSL` uses the image's public CA
bundle, so install private or provider-specific roots in a derived image.

Renga requires PostgreSQL 15 or newer. Its migrations enable the `btree_gist`
and `citext` extensions; on managed services where the application role cannot
create extensions, enable them first.

Authentication also requires outbound email. Before deploying, replace the
shipped `Swoosh.Adapters.Local` mailer with a production adapter and configure
a valid sender address. Production disables the Local adapter's in-memory
mailbox, so the default source configuration cannot deliver registration or
sign-in links.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
