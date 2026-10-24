defmodule Renga.TransfersFixtures do
  @moduledoc """
  The organization behind RFD 20's round-trip fixtures: one of each thing an
  import must treat with care.
  """

  import Ecto.Query
  import Renga.JobsFixtures

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Jobs
  alias Renga.Members
  alias Renga.Repo
  alias Renga.SavedViews

  @doc """
  An organization with, besides its owner:

    * `managed`: a member whose access a SCIM directory manages;
    * `former`: an admin who shared a saved view and was then disabled;
    * `viewer`: a member with a private saved view, `private_view`;
    * `job`: a queued job, and `resource`, a reported resource whose
      identifier claim rests on an observation.

  Returns them as scopes and records, with the `organization` and `owner`.
  """
  def round_trip_organization do
    %{organization: organization, scope: owner} = job_organization_fixture()
    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)
    {:ok, job} = Jobs.create_job(owner, agent.id, "inventory.collect@1", %{})

    managed = member_scope(organization, "member")
    connection = Renga.ScimFixtures.scim_connection_fixture(owner)

    OrganizationMembership
    |> where([membership], membership.id == ^managed.membership_id)
    |> Repo.update_all(set: [scim_connection_id: connection.id])

    former = member_scope(organization, "admin")

    {:ok, shared_view} =
      SavedViews.create_view(former, %{area: "inventory", name: "Racks", shared: true})

    {:ok, _disabled} = Members.disable_member(owner, former.membership_id)

    viewer = member_scope(organization, "viewer")
    {:ok, private_view} = SavedViews.create_view(viewer, %{area: "inventory", name: "Mine"})

    %{
      organization: organization,
      owner: owner,
      managed: managed,
      former: former,
      viewer: viewer,
      job: job,
      resource: resource,
      shared_view: shared_view,
      private_view: private_view
    }
  end
end
