defmodule CortexWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix Channel tests.

  Provides helpers from `Phoenix.ChannelTest` for testing WebSocket
  channels and sockets.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint CortexWeb.Endpoint
    end
  end
end
