defmodule CortexWeb.ErrorHTML do
  @moduledoc """
  Error pages for the Cortex web interface.
  """
  use CortexWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
