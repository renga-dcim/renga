defmodule RengaWeb.GroupComponents do
  @moduledoc """
  Pieces shared by the pages that show resource groups (RFD 18): the
  Groups settings page and a resource's own page.
  """
  use Phoenix.Component

  alias Renga.ResourceGroups.GroupSet

  @doc "A group's set, marked when exclusive, or a quiet dash when it has none."
  attr :set, :any, required: true

  def group_set_label(%{set: %GroupSet{}} = assigns) do
    ~H"""
    <span class="text-sm text-fg">
      {@set.name}<span :if={@set.exclusive} class="text-fg-muted"> · exclusive</span>
    </span>
    """
  end

  def group_set_label(assigns) do
    ~H"""
    <span class="text-sm text-fg-subtle">—</span>
    """
  end

  @doc """
  Why a membership or group change was refused, as a sentence. An exclusive
  conflict names the first resource and the groups it would be in.
  """
  def refusal_message({:exclusive_conflict, [conflict | rest]}) do
    more =
      case length(rest) do
        0 -> ""
        1 -> " (and 1 more resource)"
        count -> " (and #{count} more resources)"
      end

    "#{conflict.resource} would be in both #{Enum.join(conflict.groups, " and ")}, " <>
      "but #{conflict.group_set} is exclusive#{more}"
  end

  def refusal_message(:forbidden),
    do: "Changing group membership requires the owner or admin role"

  def refusal_message(:not_found), do: "That group or resource no longer exists"
  def refusal_message(:not_in_set), do: "That group is not in a set"
end
