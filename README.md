# Renga

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4401`](http://localhost:4401) from your browser.

## Amp orb development

Run `amp orb services ensure` in an Amp orb to start the supervised Phoenix
server and print its authenticated portal URL. `mix setup` seeds a development
workspace with representative inventory:

* Email: `demo@renga.local`
* Password: `renga-demo-password`
* Organization: `Renga Labs`

The orb lifecycle also creates an ignored, disposable Git repository at
`dev/agent-target`. It can be deleted at any time; `.agents/setup` or
`.agents/resume` recreates it for coding-agent experiments.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
