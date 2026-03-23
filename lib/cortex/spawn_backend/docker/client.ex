defmodule Cortex.SpawnBackend.Docker.Client do
  @moduledoc """
  HTTP client for the Docker Engine API over a Unix socket.

  Provides a thin wrapper around the Docker Engine REST API, communicating
  via `/var/run/docker.sock`. Uses Erlang's `:gen_tcp` with `{:local, path}`
  addressing for Unix domain socket support.

  All functions accept a keyword `:opts` list that can include:

    - `:socket_path` — path to Docker socket (default: `"/var/run/docker.sock"`)
    - `:timeout` — request timeout in ms (default: `30_000`)

  ## Test Injection

  This module is designed to be swappable. `SpawnBackend.Docker` accepts a
  `:docker_client` option that defaults to this module. Tests can provide a
  mock module implementing the same function signatures.
  """

  require Logger

  @default_socket "/var/run/docker.sock"
  @default_timeout 30_000
  @api_version "v1.43"

  # -- Public API --

  @doc "Pings the Docker daemon. Returns `:ok` or `{:error, reason}`."
  @spec ping(keyword()) :: :ok | {:error, term()}
  def ping(opts \\ []) do
    case request("GET", "/_ping", nil, opts) do
      {:ok, 200, _body} -> :ok
      {:ok, status, body} -> {:error, {:unexpected_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates a container from the given spec map. Returns `{:ok, container_id}`."
  @spec create_container(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_container(spec, opts \\ []) do
    name = Map.get(spec, "name") || Map.get(spec, :name)
    path = "/#{@api_version}/containers/create" <> if(name, do: "?name=#{name}", else: "")
    body = Map.drop(spec, ["name", :name])

    case request("POST", path, body, opts) do
      {:ok, 201, resp} ->
        {:ok, Map.fetch!(resp, "Id")}

      {:ok, 409, _resp} ->
        {:error, :container_already_exists}

      {:ok, 404, _resp} ->
        {:error, :image_not_found}

      {:ok, status, body} ->
        {:error, {:create_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Starts a container by ID."
  @spec start_container(String.t(), keyword()) :: :ok | {:error, term()}
  def start_container(id, opts \\ []) do
    case request("POST", "/#{@api_version}/containers/#{id}/start", nil, opts) do
      {:ok, status, _body} when status in [204, 304] -> :ok
      {:ok, 404, _} -> {:error, :container_not_found}
      {:ok, status, body} -> {:error, {:start_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops a container by ID. `timeout` is seconds to wait before killing."
  @spec stop_container(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_container(id, opts \\ []) do
    stop_timeout = Keyword.get(opts, :stop_timeout, 10)

    case request("POST", "/#{@api_version}/containers/#{id}/stop?t=#{stop_timeout}", nil, opts) do
      {:ok, status, _body} when status in [204, 304] -> :ok
      {:ok, 404, _} -> :ok
      {:ok, status, body} -> {:error, {:stop_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes a container by ID. Force-removes and removes volumes."
  @spec remove_container(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_container(id, opts \\ []) do
    case request("DELETE", "/#{@api_version}/containers/#{id}?force=true&v=true", nil, opts) do
      {:ok, 204, _} -> :ok
      {:ok, 404, _} -> :ok
      {:ok, status, body} -> {:error, {:remove_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Inspects a container by ID. Returns `{:ok, info_map}`."
  @spec inspect_container(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_container(id, opts \\ []) do
    case request("GET", "/#{@api_version}/containers/#{id}/json", nil, opts) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _} -> {:error, :container_not_found}
      {:ok, status, body} -> {:error, {:inspect_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a lazy stream of log lines from a container's stdout.

  Uses Docker's `GET /containers/{id}/logs?follow=true&stdout=true` endpoint.
  The stream terminates when the container exits or the connection closes.
  """
  @spec container_logs(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def container_logs(id, opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    path = "/#{@api_version}/containers/#{id}/logs?follow=true&stdout=true&stderr=true"

    case connect_socket(socket_path, timeout) do
      {:ok, socket} ->
        request_line = "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

        case :gen_tcp.send(socket, request_line) do
          :ok ->
            # Skip HTTP headers
            skip_http_headers(socket, timeout)

            stream =
              Stream.resource(
                fn -> socket end,
                fn sock ->
                  case :gen_tcp.recv(sock, 0, timeout) do
                    {:ok, data} ->
                      # Docker multiplexed stream: strip 8-byte header frames
                      chunks = strip_docker_stream_headers(data)
                      {chunks, sock}

                    {:error, :closed} ->
                      {:halt, sock}

                    {:error, _reason} ->
                      {:halt, sock}
                  end
                end,
                fn sock -> :gen_tcp.close(sock) end
              )

            {:ok, stream}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, {:send_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Creates a Docker network. Returns `{:ok, network_id}`."
  @spec create_network(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_network(name, opts \\ []) do
    spec = %{
      "Name" => name,
      "Driver" => "bridge",
      "CheckDuplicate" => true
    }

    case request("POST", "/#{@api_version}/networks/create", spec, opts) do
      {:ok, 201, resp} ->
        {:ok, Map.fetch!(resp, "Id")}

      {:ok, 409, _resp} ->
        # Network already exists — try to find it and return its ID
        case inspect_network(name, opts) do
          {:ok, %{"Id" => id}} -> {:ok, id}
          _ -> {:error, :network_already_exists}
        end

      {:ok, status, body} ->
        {:error, {:network_create_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Removes a Docker network by ID or name."
  @spec remove_network(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_network(id, opts \\ []) do
    case request("DELETE", "/#{@api_version}/networks/#{id}", nil, opts) do
      {:ok, 204, _} -> :ok
      {:ok, 404, _} -> :ok
      {:ok, status, body} -> {:error, {:network_remove_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists containers matching the given label filters."
  @spec list_containers(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_containers(filters, opts \\ []) do
    filters_json = Jason.encode!(filters)
    encoded = URI.encode(filters_json)

    case request(
           "GET",
           "/#{@api_version}/containers/json?all=true&filters=#{encoded}",
           nil,
           opts
         ) do
      {:ok, 200, body} when is_list(body) -> {:ok, body}
      {:ok, 200, body} when is_map(body) -> {:ok, [body]}
      {:ok, status, body} -> {:error, {:list_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Private Helpers --

  @spec inspect_network(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp inspect_network(name, opts) do
    case request("GET", "/#{@api_version}/networks/#{name}", nil, opts) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _} -> {:error, :network_not_found}
      {:ok, status, body} -> {:error, {:network_inspect_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request(String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, integer(), term()} | {:error, term()}
  defp request(method, path, body, opts) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, socket} <- connect_socket(socket_path, timeout),
         {:ok, status, resp_body} <- send_request(socket, method, path, body, timeout) do
      :gen_tcp.close(socket)
      {:ok, status, resp_body}
    end
  end

  @spec connect_socket(String.t(), non_neg_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  defp connect_socket(socket_path, timeout) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :enoent} ->
        {:error, :docker_unavailable}

      {:error, :econnrefused} ->
        {:error, :docker_unavailable}

      {:error, :eacces} ->
        {:error, :docker_permission_denied}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  @spec send_request(:gen_tcp.socket(), String.t(), String.t(), map() | nil, non_neg_integer()) ::
          {:ok, integer(), term()} | {:error, term()}
  defp send_request(socket, method, path, body, timeout) do
    {content_type, encoded_body} =
      case body do
        nil -> {nil, nil}
        data -> {"application/json", Jason.encode!(data)}
      end

    headers =
      [
        "#{method} #{path} HTTP/1.1",
        "Host: localhost"
      ] ++
        if(content_type, do: ["Content-Type: #{content_type}"], else: []) ++
        if(encoded_body, do: ["Content-Length: #{byte_size(encoded_body)}"], else: []) ++
        ["Connection: close", "", ""]

    request_data = Enum.join(headers, "\r\n") <> (encoded_body || "")

    case :gen_tcp.send(socket, request_data) do
      :ok ->
        receive_response(socket, timeout)

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  @spec receive_response(:gen_tcp.socket(), non_neg_integer()) ::
          {:ok, integer(), term()} | {:error, term()}
  defp receive_response(socket, timeout) do
    receive_data(socket, timeout, <<>>)
  end

  defp receive_data(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        receive_data(socket, timeout, acc <> data)

      {:error, :closed} ->
        parse_http_response(acc)

      {:error, reason} ->
        {:error, {:recv_failed, reason}}
    end
  end

  @spec parse_http_response(binary()) :: {:ok, integer(), term()} | {:error, term()}
  defp parse_http_response(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        status = parse_status_code(headers)
        decoded_body = decode_body(body, headers)
        {:ok, status, decoded_body}

      [headers_only] ->
        status = parse_status_code(headers_only)
        {:ok, status, nil}
    end
  end

  @spec parse_status_code(String.t()) :: integer()
  defp parse_status_code(headers) do
    case Regex.run(~r/HTTP\/1\.[01] (\d{3})/, headers) do
      [_, code] -> String.to_integer(code)
      _ -> 0
    end
  end

  @spec decode_body(String.t(), String.t()) :: term()
  defp decode_body(body, headers) do
    actual_body =
      if String.contains?(headers, "Transfer-Encoding: chunked") do
        decode_chunked(body)
      else
        body
      end

    case Jason.decode(actual_body) do
      {:ok, parsed} -> parsed
      {:error, _} -> actual_body
    end
  end

  @spec decode_chunked(binary()) :: binary()
  defp decode_chunked(data) do
    decode_chunks(data, <<>>)
  end

  defp decode_chunks(data, acc) do
    case String.split(data, "\r\n", parts: 2) do
      [size_hex, rest] ->
        case Integer.parse(size_hex, 16) do
          {0, _} ->
            acc

          {size, _} when byte_size(rest) >= size ->
            chunk = binary_part(rest, 0, size)
            # Skip the chunk data + trailing \r\n
            remaining_start = size + 2
            remaining_len = byte_size(rest) - remaining_start

            if remaining_len > 0 do
              remaining = binary_part(rest, remaining_start, remaining_len)
              decode_chunks(remaining, acc <> chunk)
            else
              acc <> chunk
            end

          _ ->
            # Incomplete chunk, return what we have
            acc <> data
        end

      _ ->
        acc <> data
    end
  end

  @spec skip_http_headers(:gen_tcp.socket(), non_neg_integer()) :: :ok
  defp skip_http_headers(socket, timeout) do
    skip_headers_loop(socket, timeout, <<>>)
  end

  defp skip_headers_loop(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        combined = acc <> data

        if String.contains?(combined, "\r\n\r\n") do
          :ok
        else
          skip_headers_loop(socket, timeout, combined)
        end

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Strips Docker multiplexed stream framing headers from log data.

  Docker log streams use an 8-byte header per frame:
  - Byte 0: stream type (0=stdin, 1=stdout, 2=stderr)
  - Bytes 1-3: reserved (0)
  - Bytes 4-7: payload size (big-endian uint32)
  """
  @spec strip_docker_stream_headers(binary()) :: [binary()]
  def strip_docker_stream_headers(data) do
    strip_frames(data, [])
  end

  defp strip_frames(<<_type, 0, 0, 0, size::unsigned-big-integer-size(32), rest::binary>>, acc) do
    if byte_size(rest) >= size do
      payload = binary_part(rest, 0, size)
      remaining = binary_part(rest, size, byte_size(rest) - size)
      strip_frames(remaining, [payload | acc])
    else
      # Incomplete frame — return the rest as raw data
      Enum.reverse([rest | acc])
    end
  end

  defp strip_frames(<<>>, acc), do: Enum.reverse(acc)

  # If the data doesn't match the multiplexed format, return it as-is
  defp strip_frames(data, acc), do: Enum.reverse([data | acc])
end
