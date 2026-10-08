# Renga

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

Product and architecture decisions live in [Requests for Discussion](rfd/README.md).
Run `make check-rfds` after changing an RFD or its implementation checklist.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
