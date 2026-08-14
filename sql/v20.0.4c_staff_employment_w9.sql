-- v20.0.4c — staff: employment classification + W-9 compliance date (D4)
-- Existing rows backfill to 'w2' automatically via the NOT NULL DEFAULT.

ALTER TABLE staff
  ADD COLUMN employment_type text NOT NULL DEFAULT 'w2',
  ADD COLUMN w9_received_at  date;

ALTER TABLE staff
  ADD CONSTRAINT staff_employment_type_values
    CHECK (employment_type IN ('w2','contractor_1099'));
