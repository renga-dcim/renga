defmodule RengaWeb.DeletionHTML do
  use RengaWeb, :html

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_page
        id="deletion-recovery"
        title="Deletion recovery"
        description="Pending deletion blocks ordinary organization access. Owners can cancel or export until purge begins."
      >
        <p :if={@rows == []} id="no-pending-deletions" class="text-sm text-fg-muted">
          No pending deletions are available to this sign-in. If your organization requires MFA, sign in with MFA first.
        </p>
        <.settings_section
          :for={row <- @rows}
          id={"deletion-#{row.organization.id}"}
          title={row.organization.name}
        >
          <p class="text-sm text-fg-muted">
            Deletion deadline: {RengaWeb.Format.datetime(row.organization.deletion_due_at)}
          </p>
          <div class="flex flex-wrap gap-3">
            <.form
              for={@cancel_form}
              id={"cancel-deletion-#{row.organization.id}"}
              action={~p"/organizations/deletions/#{row.organization.id}/cancel"}
            >
              <.button type="submit" variant="primary">Cancel deletion</.button>
            </.form>
            <.form
              for={@export_form}
              id={"export-deletion-#{row.organization.id}"}
              action={~p"/organizations/deletions/#{row.organization.id}/export"}
            >
              <.button type="submit" variant="secondary">Request export</.button>
            </.form>
          </div>
          <ul id={"exports-#{row.organization.id}"} class="space-y-2 text-sm text-fg-muted">
            <li :for={export <- row.exports}>
              Export: {export.status}
              <.link
                :if={export.status == "ready"}
                href={~p"/organizations/deletions/#{row.organization.id}/exports/#{export.id}"}
                class="text-link underline"
              >Download archive</.link>
            </li>
          </ul>
        </.settings_section>
      </.settings_page>
    </Layouts.app>
    """
  end
end
