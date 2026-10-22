defmodule RengaWeb.QueryComponentsTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RengaWeb.QueryComponents

  defmodule FreshParameter do
    @moduledoc false
    use Renga.Jobs.Query

    def name, do: "query.fresh_parameter"
    def version, do: 1
    def title, do: "Fresh parameter"
    def noun, do: "fresh parameter query"
    def summary, do: "A parameter no code has named as an atom"
    def sensitivity, do: :inventory

    def parameters_schema,
      do: {:object, [{"rfd12_parameter_seen_first_by_the_form", {:optional, :boolean}}]}

    def result_schema, do: {:object, []}
    def describe_result(_result), do: "Completed"
  end

  test "renders a parameter whose name is not an atom yet" do
    html =
      render_component(&parameter_fields/1, form: parameters_form(%{}), module: FreshParameter)

    assert html =~ ~s(name="query[rfd12_parameter_seen_first_by_the_form]")
  end
end
