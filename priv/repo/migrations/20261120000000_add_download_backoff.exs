defmodule Pinchflat.Repo.Migrations.AddDownloadBackoff do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :download_failure_count, :integer, default: 0, null: false
      add :download_retry_after, :utc_datetime
    end

    alter table(:settings) do
      add :downloads_paused_until, :utc_datetime
    end
  end
end
