defmodule CortexWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Provides helpers from Phoenix.ConnTest and Phoenix.LiveViewTest
  for testing LiveViews and controllers.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      @endpoint CortexWeb.Endpoint
    end
  end

  setup _tags do
    # Check out a DB connection for tests that need Ecto sandbox
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cortex.Repo, caller: self())
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
