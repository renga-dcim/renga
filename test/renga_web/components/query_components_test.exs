defmodule RengaWeb.QueryComponentsTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RengaWeb.QueryComponents

  defmodule FreshParameter do
    @moduledoc false
    use Renga.Jobs.Query

    @impl true
    def name, do: "query.fresh_parameter"

    @impl true
    def version, do: 1

    @impl true
    def title, do: "Fresh parameter"

    @impl true
    def noun, do: "fresh parameter query"

    @impl true
    def summary, do: "A parameter no code has named as an atom"

    @impl true
    def sensitivity, do: :inventory

    @impl true
    def parameters_schema,
      do: {:object, [{"rfd12_parameter_seen_first_by_the_form", {:optional, :boolean}}]}

    @impl true
    def result_schema, do: {:object, []}

    @impl true
    def describe_result(_result), do: "Completed"
  end

  test "renders a parameter whose name is not an atom yet" do
    html =
      render_component(&parameter_fields/1, form: parameters_form(%{}), module: FreshParameter)

    assert html =~ ~s(name="query[rfd12_parameter_seen_first_by_the_form]")
  end
end
