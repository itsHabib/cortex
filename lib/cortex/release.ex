defmodule Cortex.Release do
  @moduledoc """
  Release tasks for Cortex.

  Used by the release entrypoint scripts to run migrations before
  starting the application. Can also be invoked via:

      bin/cortex eval "Cortex.Release.migrate()"

  """

  @app :cortex

  @doc """
  Run all pending Ecto migrations.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Roll back the last migration.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
