-- The app connects as invai_app: not the table owner, no BYPASSRLS, so row-level security applies.
CREATE ROLE invai_app LOGIN PASSWORD 'invai';
GRANT ALL ON DATABASE invai TO invai_app;
