defmodule RengaWeb.Api.V1.Schemas.JobLease do
  @moduledoc false

  alias RengaWeb.Api.V1.Schemas.JobOffer
  alias RengaWeb.Api.V1.Schemas.LeasedJob

  def json_schema do
    %{
      title: "JobLease",
      description:
        "Jobs leased to the calling installation, possibly none, and privileged jobs " <>
          "offered to it. Each lease lasts until `lease_expires_at`; every newly recorded " <>
          "report extends it.",
      type: :object,
      properties: %{
        jobs: %{type: :array, items: LeasedJob},
        offers: %{
          type: :array,
          description:
            "Privileged jobs (RFD 13) the installation may claim by signing for them with " <>
              "its approved installation key. Absent from older servers.",
          items: JobOffer
        }
      },
      required: [:jobs],
      additionalProperties: false
    }
  end
end
