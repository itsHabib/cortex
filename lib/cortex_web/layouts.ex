defmodule CortexWeb.Layouts do
  @moduledoc """
  Layout components for CortexWeb.
  """
  use CortexWeb, :html

  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates("layouts/*")
end
