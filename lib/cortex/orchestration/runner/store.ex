defmodule Cortex.Orchestration.Runner.Store do
  @moduledoc """
  Safe database operation wrappers for the Runner sub-modules.

  All orchestration DB calls are wrapped in `safe_call/1` so that store
  failures never crash the coordinator process. This module also provides
  `truncate_summary/1` to cap text before DB insertion.
  """

  @doc """
  Wraps a database call in try/rescue so that store failures never crash
  the orchestration coordinator.

  Returns the result of `fun.()` on success, or `:ok` if the call raises.
  """
  @spec safe_call((-> any())) :: any()
  def safe_call(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    end
  end

  @doc """
  Truncates text to at most 2 000 characters for safe DB storage.

  - `nil` passes through as `nil`.
  - Binaries longer than 2 000 chars are sliced and suffixed with `"..."`.
  - Non-binary terms are `inspect/1`-ed first, then truncated.
  """
  @spec truncate_summary(term()) :: String.t() | nil
  def truncate_summary(nil), do: nil

  def truncate_summary(text) when is_binary(text) do
    if String.length(text) > 2000 do
      String.slice(text, 0, 2000) <> "..."
    else
      text
    end
  end

  def truncate_summary(other), do: inspect(other) |> truncate_summary()
end
