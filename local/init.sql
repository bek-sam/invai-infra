-- The app connects as invai_app: not the table owner, no BYPASSRLS, so row-level security applies.
-- Migrations run as invai (the owner / POSTGRES_USER), so invai_app needs default privileges on
-- whatever invai creates later.
CREATE ROLE invai_app LOGIN PASSWORD 'invai';

-- Same setup in a second database for tests (invai_test).
CREATE DATABASE invai_test OWNER invai;

\connect invai

GRANT ALL ON DATABASE invai TO invai_app;
GRANT USAGE ON SCHEMA public TO invai_app;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- Tables/sequences invai creates from here on (migrations) are usable by invai_app without a
-- manual GRANT after every migration.
ALTER DEFAULT PRIVILEGES FOR ROLE invai IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO invai_app;
ALTER DEFAULT PRIVILEGES FOR ROLE invai IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO invai_app;

\connect invai_test

GRANT ALL ON DATABASE invai_test TO invai_app;
GRANT USAGE ON SCHEMA public TO invai_app;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

ALTER DEFAULT PRIVILEGES FOR ROLE invai IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO invai_app;
ALTER DEFAULT PRIVILEGES FOR ROLE invai IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO invai_app;
