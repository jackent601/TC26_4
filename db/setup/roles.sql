-- Runs after every migration run (db-roles service), as the database owner.
--  * Sets login passwords from .env, so changing a password in .env and
--    re-running applies it.
--  * Tells PostgREST to reload its schema cache, so new or changed api views
--    and functions are served without restarting it.
-- Usage: psql -v api_password=... -f roles.sql
\set ON_ERROR_STOP on
alter role api_user with login password :'api_password';
notify pgrst, 'reload schema';
