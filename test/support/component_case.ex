defmodule CortexWeb.ComponentCase do
  @moduledoc """
  Lightweight test case for pure component tests that do not need
  database access or a live connection.

  Use this instead of ConnCase when the test only calls render_component/2.
  It skips the Ecto sandbox checkout entirely, avoiding pool exhaustion
  when many component tests run in parallel.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.LiveViewTest
    end
  end
end
