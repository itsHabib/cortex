defmodule Cortex.Repo.Migrations.AddTokensToTeamRuns do
  use Ecto.Migration

  def change do
    alter table(:team_runs) do
      add(:input_tokens, :integer)
      add(:output_tokens, :integer)
      add(:cache_read_tokens, :integer)
      add(:cache_creation_tokens, :integer)
    end

    alter table(:runs) do
      add(:total_input_tokens, :integer)
      add(:total_output_tokens, :integer)
    end
  end
end
