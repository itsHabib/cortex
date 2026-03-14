defmodule Cortex.Logger do
  @moduledoc """
  Structured logging wrapper for Cortex operations.

  Adds consistent `[cortex: true]` metadata to all log messages, making
  Cortex log lines easily filterable in aggregated log streams. Additional
  keyword metadata can be passed per-call for structured context.

  ## Usage

      Cortex.Logger.info("Run started", project: "demo", team_count: 5)
      Cortex.Logger.error("Team failed", team: "backend", reason: :timeout)

  All log lines will include `cortex: true` in their metadata, plus any
  additional keywords passed. This enables log filtering like:

      config :logger, :console,
        metadata: [:cortex, :project, :team]

  """

  require Logger

  @doc """
  Logs an info-level message with Cortex metadata.

  ## Parameters

    - `message` -- the log message string
    - `metadata` -- optional keyword list of additional metadata

  """
  @spec info(String.t(), keyword()) :: :ok
  def info(message, metadata \\ []) do
    Logger.info(message, build_metadata(metadata))
    :ok
  end

  @doc """
  Logs a warning-level message with Cortex metadata.

  ## Parameters

    - `message` -- the log message string
    - `metadata` -- optional keyword list of additional metadata

  """
  @spec warn(String.t(), keyword()) :: :ok
  def warn(message, metadata \\ []) do
    Logger.warning(message, build_metadata(metadata))
    :ok
  end

  @doc """
  Logs an error-level message with Cortex metadata.

  ## Parameters

    - `message` -- the log message string
    - `metadata` -- optional keyword list of additional metadata

  """
  @spec error(String.t(), keyword()) :: :ok
  def error(message, metadata \\ []) do
    Logger.error(message, build_metadata(metadata))
    :ok
  end

  @doc """
  Logs a debug-level message with Cortex metadata.

  ## Parameters

    - `message` -- the log message string
    - `metadata` -- optional keyword list of additional metadata

  """
  @spec debug(String.t(), keyword()) :: :ok
  def debug(message, metadata \\ []) do
    Logger.debug(message, build_metadata(metadata))
    :ok
  end

  @spec build_metadata(keyword()) :: keyword()
  defp build_metadata(extra) do
    [{:cortex, true} | extra]
  end
end
