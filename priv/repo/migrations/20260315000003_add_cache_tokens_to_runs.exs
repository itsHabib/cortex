defmodule Cortex.Repo.Migrations.AddCacheTokensToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:total_cache_read_tokens, :integer)
      add(:total_cache_creation_tokens, :integer)
    end
  end
end
