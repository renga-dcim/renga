defmodule Renga.Repo.Migrations.LetImportedJobsLoseDeletedReferences do
  use Ecto.Migration

  # An imported job names its resource, target binding, and requester with
  # ON DELETE SET NULL. Deleting one of those must still leave the job as
  # history, so the trigger lets those references become null and refuses
  # every other change.
  def change do
    execute(
      """
      CREATE OR REPLACE FUNCTION reject_imported_job_update() RETURNS trigger AS $$
      BEGIN
        IF (to_jsonb(NEW) - '{resource_id,target_binding_id,requested_by_user_id}'::text[])
             = (to_jsonb(OLD) - '{resource_id,target_binding_id,requested_by_user_id}'::text[])
           AND (NEW.resource_id IS NULL OR NEW.resource_id = OLD.resource_id)
           AND (NEW.target_binding_id IS NULL OR NEW.target_binding_id = OLD.target_binding_id)
           AND (NEW.requested_by_user_id IS NULL
                OR NEW.requested_by_user_id = OLD.requested_by_user_id) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'imported jobs are history and cannot change'
          USING ERRCODE = '23514', CONSTRAINT = 'jobs_imported_immutable';
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION reject_imported_job_update() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'imported jobs are history and cannot change'
          USING ERRCODE = '23514', CONSTRAINT = 'jobs_imported_immutable';
      END;
      $$ LANGUAGE plpgsql
      """
    )
  end
end
