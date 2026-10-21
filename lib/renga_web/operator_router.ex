defmodule RengaWeb.OperatorRouter do
  @moduledoc """
  Routes of the operator API (RFD 22), served only by
  `RengaWeb.OperatorEndpoint`. Every route requires an operator token;
  routes that change or read organization data also require a scope with
  `RengaWeb.OperatorAuth.require_scope/2`.
  """

  use RengaWeb, :router

  pipeline :operator do
    plug :accepts, ["json"]
    plug RengaWeb.OperatorAuth
  end

  scope "/operator/v1", RengaWeb.Operator.V1 do
    pipe_through :operator

    get "/openapi.json", OpenApiController, :show
    get "/deployment", DeploymentController, :show
    delete "/tokens/self", TokenController, :delete_self
  end
end
