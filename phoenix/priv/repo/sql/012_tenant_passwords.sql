-- Passwords for customer accounts.
--
-- Optional, and additional: the emailed link still signs anyone in, still
-- creates the account on first use, and is therefore also the password reset
-- — there is nothing to forget that a link cannot fix. Setting a password is
-- for people who sign in often enough that waiting on mail is the friction.
--
-- Same scrypt encoding as admins (src/utils/password.mjs), so the parameters
-- travel with the hash and can be raised later without invalidating anything.

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS password_hash   text,
  ADD COLUMN IF NOT EXISTS password_set_at timestamptz;
