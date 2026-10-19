defmodule RengaUIConsumer do
  use Phoenix.Component

  import RengaUI.Components
  import RengaUI.CoreComponents

  def sample(assigns) do
    ~H"""
    <main class="bg-canvas p-4 text-fg">
      <.input
        id="consumer-name"
        name="name"
        label="Name"
        value=""
        errors={["can't be blank"]}
      />
      <.icon name="hero-x-mark" />
      <.side_panel id="consumer-panel" title="Package overlay" show>
        Shared content
      </.side_panel>
    </main>
    """
  end
end
