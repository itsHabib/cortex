defmodule Cortex.Repo.Migrations.AddInternalToTeamRuns do
  use Ecto.Migration

  def change do
    alter table(:team_runs) do
      add :internal, :boolean, default: false, null: false
    end

    # Backfill existing internal teams
    flush()

    execute(
      "UPDATE team_runs SET internal = 1 WHERE team_name IN ('coordinator', 'summary-agent', 'debug-agent')",
      "UPDATE team_runs SET internal = 0 WHERE team_name IN ('coordinator', 'summary-agent', 'debug-agent')"
    )
  end
end
