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
| `PHX_HOST` | yes | Public host name used in generated URLs |
| `DATABASE_SSL` | no | `true` to require TLS, verifying the server certificate against the OS trust store and the URL's host name; any `ssl` query option in `DATABASE_URL` must also be `true` |
| `POOL_SIZE` | no | Database connections per node (default 10) |
| `DATABASE_STATEMENT_TIMEOUT` | no | Longest a single application statement may run, in milliseconds (default 30000), so one organization's slow query cannot hold a connection others need (RFD 21). `bin/migrate` runs without it |
| `DATABASE_BACKGROUND_STATEMENT_TIMEOUT` | no | Longer per-statement limit for approved background work such as job history purges, in milliseconds (default 300000) |
| `ECTO_IPV6` | no | `true` to reach the database over IPv6 |
| `DNS_CLUSTER_QUERY` | no | DNS name that resolves to every node, for clustering |
| `PORT` | no | HTTP port (default 4000) |

Run `/app/bin/migrate` once per deploy, before new nodes start, then run
`/app/bin/server`. Put the server behind a TLS-terminating reverse proxy; the
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
