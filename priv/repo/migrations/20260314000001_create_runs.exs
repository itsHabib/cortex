defmodule Cortex.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :config_yaml, :text
      add :status, :string, null: false, default: "pending"
      add :team_count, :integer, default: 0
      add :total_cost_usd, :float, default: 0.0
      add :total_duration_ms, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:status])
    create index(:runs, [:inserted_at])
  end
end
