# Browser tests (tagged :playwright) need the Playwright npm package from
# `mix assets.setup`, the asset build tools, and matching browsers (provided by the Nix dev shell).
# Without it they are skipped locally, but CI must never skip them silently.
playwright? = File.exists?("assets/node_modules/playwright/package.json")

cond do
  playwright? ->
    # The browser loads the built bundles, which are not tracked; rebuild them
    # so browser tests never run against stale CSS or hooks.
    Mix.Task.run("tailwind", ["renga"])
    Mix.Task.run("esbuild", ["renga"])

    {:ok, playwright_supervisor} = PhoenixTest.Playwright.Supervisor.start_link()
    # Short, non-browser suites can finish while Node is still emitting its
    # initial protocol messages. Wait for readiness before allowing teardown.
    PlaywrightEx.Connection.initializer!(PlaywrightEx.Supervisor.Connection, "Playwright")
    Application.put_env(:phoenix_test, :base_url, RengaWeb.Endpoint.url())
    ExUnit.start()

    # Close browser pools and their transport before the VM tears down Node's pipe.
    ExUnit.after_suite(fn _result ->
      Supervisor.stop(playwright_supervisor, :normal, :infinity)
    end)

  System.get_env("CI") ->
    raise "browser tests need Playwright: run `npm ci --prefix assets` before `mix test`"

  true ->
    IO.puts("Skipping :playwright browser tests; run `mix assets.setup` to install Playwright.")
    ExUnit.start(exclude: [:playwright])
end

Ecto.Adapters.SQL.Sandbox.mode(Renga.Repo, :manual)
