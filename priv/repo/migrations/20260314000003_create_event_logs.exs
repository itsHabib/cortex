defmodule Cortex.Repo.Migrations.CreateEventLogs do
  use Ecto.Migration

  def change do
    create table(:event_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :string
      add :event_type, :string, null: false
      add :payload, :map, default: %{}
      add :source, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:event_logs, [:run_id])
    create index(:event_logs, [:event_type])
    create index(:event_logs, [:inserted_at])
  end
end
