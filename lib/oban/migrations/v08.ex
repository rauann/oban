defmodule Oban.Migrations.V08 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    alter table(:oban_jobs, prefix: prefix) do
      add_if_not_exists(:discarded_at, :utc_datetime_usec)
      add_if_not_exists(:priority, :integer)
      add_if_not_exists(:tags, {:array, :string})
    end

    alter table(:oban_jobs, prefix: prefix) do
      modify :priority, :integer, default: 0
      modify :tags, {:array, :string}, default: []
    end

    drop_if_exists index(:oban_jobs, [:queue, :state, :scheduled_at, :id], prefix: prefix)

    create_if_not_exists index(:oban_jobs, [:queue, :state, :priority, :scheduled_at, :id],
                           prefix: prefix
                         )

    execute """
    CREATE OR REPLACE FUNCTION #{prefix}.oban_jobs_notify() RETURNS trigger AS $$
    DECLARE
      channel text;
      notice json;
    BEGIN
      IF NEW.state = 'available' THEN
        channel = '#{prefix}.oban_insert';
        notice = json_build_object('queue', NEW.queue);

        PERFORM pg_notify(channel, notice::text);
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute "DROP TRIGGER IF EXISTS oban_notify ON #{prefix}.oban_jobs"

    execute """
    CREATE TRIGGER oban_notify
    AFTER INSERT ON #{prefix}.oban_jobs
    FOR EACH ROW EXECUTE PROCEDURE #{prefix}.oban_jobs_notify();
    """
  end

  def down(%{prefix: prefix}) do
    drop_if_exists index(:oban_jobs, [:queue, :state, :priority, :scheduled_at, :id],
                     prefix: prefix
                   )

    create_if_not_exists index(:oban_jobs, [:queue, :state, :scheduled_at, :id], prefix: prefix)

    alter table(:oban_jobs, prefix: prefix) do
      remove_if_exists(:discarded_at, :utc_datetime_usec)
      remove_if_exists(:priority, :integer)
      remove_if_exists(:tags, {:array, :string})
    end

    execute """
    CREATE OR REPLACE FUNCTION #{prefix}.oban_jobs_notify() RETURNS trigger AS $$
    DECLARE
      channel text;
      notice json;
    BEGIN
      IF (TG_OP = 'INSERT') THEN
        channel = '#{prefix}.oban_insert';
        notice = json_build_object('queue', NEW.queue, 'state', NEW.state);

        -- No point triggering for a job that isn't scheduled to run now
        IF NEW.scheduled_at IS NOT NULL AND NEW.scheduled_at > now() AT TIME ZONE 'utc' THEN
          RETURN null;
        END IF;
      ELSE
        channel = '#{prefix}.oban_update';
        notice = json_build_object('queue', NEW.queue, 'new_state', NEW.state, 'old_state', OLD.state);
      END IF;

      PERFORM pg_notify(channel, notice::text);

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute "DROP TRIGGER IF EXISTS oban_notify ON #{prefix}.oban_jobs"

    execute """
    CREATE TRIGGER oban_notify
    AFTER INSERT OR UPDATE OF state ON #{prefix}.oban_jobs
    FOR EACH ROW EXECUTE PROCEDURE #{prefix}.oban_jobs_notify();
    """
  end
end
