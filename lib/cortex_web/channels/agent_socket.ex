defmodule CortexWeb.AgentSocket do
  @moduledoc """
  Phoenix Socket for external agent WebSocket connections.

  Agents connect to `/agent/websocket` and authenticate via a bearer token
  passed as `params["token"]`. On success the socket assigns `authenticated: true`,
  the connection timestamp, and the peer IP address.

  ## Connection flow

  1. Client opens `ws://host/agent/websocket?token=<bearer>`
  2. `connect/3` validates the token via `Gateway.Auth.authenticate/1`
  3. On success, assigns are set and the socket is accepted
  4. On failure, the connection is refused at the transport level
  """

  use Phoenix.Socket

  require Logger

  alias Cortex.Gateway.Auth

  channel("agent:*", CortexWeb.AgentChannel)

  @impl true
  @doc """
  Authenticates an incoming WebSocket connection using a bearer token.

  Expects `params["token"]` to contain a valid gateway token.
  Returns `{:ok, socket}` on success or `:error` on failure.
  """
  @spec connect(map(), Phoenix.Socket.t(), map()) :: {:ok, Phoenix.Socket.t()} | :error
  def connect(%{"token" => token}, socket, connect_info) when is_binary(token) do
    case Auth.authenticate(token) do
      {:ok, _identity} ->
        socket =
          socket
          |> assign(:authenticated, true)
          |> assign(:connect_time, DateTime.utc_now())
          |> assign(:remote_ip, extract_ip(connect_info))

        {:ok, socket}

      {:error, :unauthorized} ->
        Logger.warning("AgentSocket: connection refused — invalid token")
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    Logger.warning("AgentSocket: connection refused — missing token")
    :error
  end

  @impl true
  @doc """
  Returns a socket identifier for disconnect tracking.

  Returns `nil` before registration (no agent_id yet) or
  `"agent_socket:<agent_id>"` after registration.
  """
  @spec id(Phoenix.Socket.t()) :: String.t() | nil
  def id(socket) do
    case socket.assigns[:agent_id] do
      nil -> nil
      agent_id -> "agent_socket:#{agent_id}"
    end
  end

  defp extract_ip(%{peer_data: %{address: address}}) do
    address |> :inet.ntoa() |> to_string()
  end

  defp extract_ip(_), do: "unknown"
end
