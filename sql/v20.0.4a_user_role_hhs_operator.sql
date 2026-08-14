-- v20.0.4a — add hhs_operator to user_role
-- RUN THIS FILE ALONE, FIRST.
-- Postgres cannot USE a new enum value in the same transaction that adds it,
-- so this must commit on its own before any later migration references it.

ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'hhs_operator';
