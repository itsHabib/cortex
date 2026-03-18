defmodule Cortex.Gateway.Auth do
  @moduledoc """
  Authentication behaviour and dispatcher for the agent gateway.

  Defines a behaviour (`@callback authenticate/2`) that auth backends implement.
  The default backend is `Cortex.Gateway.Auth.Bearer`, which validates tokens
  against the `CORTEX_GATEWAY_TOKEN` environment variable.

  ## Configuration

  The auth backend is configured via application config:

      config :cortex, Cortex.Gateway.Auth, backend: Cortex.Gateway.Auth.Bearer

  If no config is set, defaults to `Cortex.Gateway.Auth.Bearer`.

  ## Usage

      iex> Auth.authenticate("valid-token")
      {:ok, %{identity: "bearer"}}

      iex> Auth.authenticate("wrong-token")
      {:error, :unauthorized}

  ## Testing

  Pass `token_source: "expected-token"` to inject the expected token in tests
  instead of relying on the `CORTEX_GATEWAY_TOKEN` environment variable:

      Auth.authenticate("my-token", token_source: "my-token")

  ## Security

    - Token comparison uses `Plug.Crypto.secure_compare/2` for constant-time
      comparison (prevents timing attacks).
    - The auth module fails closed: if the token source is `nil` or empty,
      authentication always fails.
    - Bearer tokens are never logged.
  """

  @doc """
  Callback that auth backends must implement.

  Receives the token string and an options keyword list. Returns
  `{:ok, identity_map}` on success or `{:error, :unauthorized}` on failure.
  """
  @callback authenticate(token :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, :unauthorized}

  @doc """
  Authenticates a bearer token using the configured backend.

  Returns `{:ok, %{identity: "bearer"}}` on success or
  `{:error, :unauthorized}` on failure.
  """
  @spec authenticate(String.t()) :: {:ok, map()} | {:error, :unauthorized}
  def authenticate(token) when is_binary(token) do
    authenticate(token, [])
  end

  def authenticate(_), do: {:error, :unauthorized}

  @doc """
  Authenticates a bearer token with options.

  Options are passed through to the configured backend. The `Bearer` backend
  supports:

    - `token_source` — the expected token string (overrides env var; useful for testing)
  """
  @spec authenticate(String.t(), keyword()) :: {:ok, map()} | {:error, :unauthorized}
  def authenticate(token, opts) when is_binary(token) and is_list(opts) do
    backend().authenticate(token, opts)
  end

  defp backend do
    Application.get_env(:cortex, __MODULE__, [])
    |> Keyword.get(:backend, Cortex.Gateway.Auth.Bearer)
  end
end

defmodule Cortex.Gateway.Auth.Bearer do
  @moduledoc """
  Bearer token authentication backend.

  Validates tokens against the `CORTEX_GATEWAY_TOKEN` environment variable
  using constant-time comparison via `Plug.Crypto.secure_compare/2`.

  ## Fail-Closed Behavior

  If the `CORTEX_GATEWAY_TOKEN` environment variable is not set (or is empty),
  all authentication attempts are rejected. This prevents accidental open access.
  """

  @behaviour Cortex.Gateway.Auth

  @doc """
  Authenticates a bearer token.

  Compares `token` against the expected value from the `CORTEX_GATEWAY_TOKEN`
  environment variable (or the `token_source` option if provided).

  Uses `Plug.Crypto.secure_compare/2` for timing-attack-safe comparison.

  ## Options

    - `token_source` — override the expected token (useful for testing)
  """
  @impl Cortex.Gateway.Auth
  @spec authenticate(String.t(), keyword()) :: {:ok, map()} | {:error, :unauthorized}
  def authenticate(token, opts \\ []) when is_binary(token) do
    expected =
      case Keyword.get(opts, :token_source) do
        nil -> System.get_env("CORTEX_GATEWAY_TOKEN")
        source -> source
      end

    if is_binary(expected) and byte_size(expected) > 0 and
         Plug.Crypto.secure_compare(token, expected) do
      {:ok, %{identity: "bearer"}}
    else
      {:error, :unauthorized}
    end
  end
end
