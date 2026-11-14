-- Sets login passwords from .env. Run by the db-roles service after migrations,
-- every time, so changing the password in .env and re-running migrate applies it.
-- Usage: psql "$DATABASE_URL" -v api_password=... -f roles.sql
\set ON_ERROR_STOP on
alter role api_user with login password :'api_password';
