defmodule RengaUI.Gettext do
  @moduledoc """
  The Gettext backend for the strings the shared components render, such as
  `"close"` and the form error messages `RengaUI.CoreComponents.translate_error/1`
  looks up in the `"errors"` domain.
  """
  use Gettext.Backend, otp_app: :renga_ui
end
