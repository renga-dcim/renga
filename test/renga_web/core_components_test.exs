defmodule RengaWeb.CoreComponentsTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias RengaWeb.CoreComponents

  test "field inputs preserve custom accessible error IDs" do
    form =
      %{"name" => ""}
      |> to_form(as: :item, errors: [name: {"is invalid", []}], action: :validate)

    html =
      render_component(&CoreComponents.input/1,
        field: form[:name],
        type: "text",
        error_id: "custom-name-error"
      )

    document = LazyHTML.from_fragment(html)
    input = LazyHTML.query(document, "input[aria-describedby='custom-name-error']")
    assert LazyHTML.attribute(input, "aria-describedby") == ["custom-name-error"]

    assert LazyHTML.to_html(LazyHTML.query(document, "#custom-name-error[role='alert']")) != ""
  end

  test "manual inputs derive an accessible error relationship" do
    html =
      render_component(&CoreComponents.input/1,
        name: "manual-name",
        type: "text",
        value: "",
        errors: ["is invalid"]
      )

    document = LazyHTML.from_fragment(html)
    input = LazyHTML.query(document, "#manual-name[aria-invalid='true']")
    assert LazyHTML.attribute(input, "aria-describedby") == ["manual-name-error"]

    assert LazyHTML.to_html(LazyHTML.query(document, "#manual-name-error[role='alert']")) != ""
  end

  test "inputs do not reference an error container when there are no visible errors" do
    form = to_form(%{"name" => ""}, as: :item)

    html =
      render_component(&CoreComponents.input/1,
        field: form[:name],
        type: "text",
        error_id: "custom-name-error"
      )

    document = LazyHTML.from_fragment(html)
    input = LazyHTML.query(document, "input")
    assert LazyHTML.attribute(input, "aria-describedby") == []
    assert LazyHTML.to_html(LazyHTML.query(document, "#custom-name-error")) == ""
  end
end
