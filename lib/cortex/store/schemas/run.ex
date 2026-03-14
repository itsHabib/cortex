defmodule Cortex.Store.Schemas.Run do
  @moduledoc """
  Ecto schema for an orchestration run.

  Tracks the overall execution of an orchestra.yaml configuration,
  including aggregate cost, duration, and status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cortex.Store.Schemas.TeamRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runs" do
    field(:name, :string)
    field(:config_yaml, :string)
    field(:status, :string, default: "pending")
    field(:team_count, :integer, default: 0)
    field(:total_cost_usd, :float, default: 0.0)
    field(:total_duration_ms, :integer)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    has_many(:team_runs, TeamRun)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(config_yaml status team_count total_cost_usd total_duration_ms started_at completed_at)a

  def changeset(run, attrs) do
    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ~w(pending running completed failed))
  end
end
