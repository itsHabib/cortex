defmodule Cortex.Repo.Migrations.CreateTeamRuns do
  use Ecto.Migration

  def change do
    create table(:team_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :team_name, :string, null: false
      add :role, :string
      add :status, :string, null: false, default: "pending"
      add :tier, :integer
      add :cost_usd, :float, default: 0.0
      add :duration_ms, :integer
      add :num_turns, :integer
      add :session_id, :string
      add :result_summary, :text
      add :prompt, :text
      add :log_path, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:team_runs, [:run_id])
    create index(:team_runs, [:run_id, :team_name])
    create index(:team_runs, [:status])
  end
end
