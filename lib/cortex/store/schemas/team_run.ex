defmodule Cortex.Store.Schemas.TeamRun do
  @moduledoc """
  Ecto schema for a single team's execution within a run.

  Tracks per-team cost, duration, status, and output for
  individual agents within an orchestration run.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cortex.Store.Schemas.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_runs" do
    field(:team_name, :string)
    field(:role, :string)
    field(:status, :string, default: "pending")
    field(:tier, :integer)
    field(:cost_usd, :float, default: 0.0)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:cache_read_tokens, :integer)
    field(:cache_creation_tokens, :integer)
    field(:duration_ms, :integer)
    field(:num_turns, :integer)
    field(:session_id, :string)
    field(:result_summary, :string)
    field(:prompt, :string)
    field(:log_path, :string)
    field(:internal, :boolean, default: false)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:run, Run)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(team_name run_id)a
  @optional_fields ~w(role status tier cost_usd input_tokens output_tokens cache_read_tokens cache_creation_tokens duration_ms num_turns session_id result_summary prompt log_path internal started_at completed_at)a

  def changeset(team_run, attrs) do
    team_run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ~w(pending running completed failed stopped))
    |> foreign_key_constraint(:run_id)
  end
end
