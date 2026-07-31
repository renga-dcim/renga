defmodule Renga.Mailer do
  @moduledoc """
  Central mail delivery boundary for account and operational notifications.
  """

  use Swoosh.Mailer, otp_app: :renga
end
