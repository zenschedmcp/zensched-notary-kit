-- ZenSched Mobile-Notary Local Database Schema
-- SQLite database for clients (signing services, title/escrow, lenders, direct
-- signers), a cache of signing addresses, the notary roster, one-off signing
-- appointments, a journal INDEX (pointers into the real notary journal), mileage,
-- client invoices / receivables, and subcontractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my notary-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 notary-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT YOUR NOTARY JOURNAL. Many states require a bound or state-approved
-- electronic journal, and the entries in it (signer name, ID type AND number,
-- signature, thumbprint where required) are governed by state law. The
-- journal_index table below only POINTS at your real journal (book label, entry
-- number, page) and records the notarial act type and count. It never stores ID
-- numbers, SSNs, dates of birth, loan numbers, or thumbprints. Neither does
-- anything else in this file.
--
-- PRIVACY: signer names, signer phone numbers, and access notes (gate codes,
-- unit numbers, "call from the lobby") live ONLY in this file on your computer:
-- appointments.signer_name, appointments.signer_phone, appointments.access_notes,
-- places.access_notes, notaries.commission_number. ZenSched receives, per signing,
-- a place label (client + city, or "Signing A-2026-0001"), the street address for
-- the GPS pin, an event title made of the signing type and appointment number,
-- and the Signing Completion Record the notary fills in on the phone.
-- SKILL.md forbids the agent from putting any local-only column into a ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Mobile Notary');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_notary_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_appointment_minutes', '60');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_travel_buffer_minutes', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('completion_form_id', NULL);
-- IRS standard mileage rate for business use. 0.70 is the 2025 rate ($0.70/mile);
-- the IRS announces a new rate each December. Update this once a year.
INSERT OR IGNORE INTO settings (key, value) VALUES ('irs_mileage_rate', '0.70');

-- Clients: who hires you and who pays you. A signing service (Snapdocs, Notary
-- Dash, a national platform), a title/escrow office, a lender, an attorney, or a
-- direct signer paying at the table. payment_terms_days drives invoice due dates;
-- the default_* fees are what the agent uses when a confirmation does not state
-- a fee (a trigger copies them onto the appointment).
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'signing_service'
    CHECK (client_type IN ('signing_service', 'title_escrow', 'lender', 'attorney', 'direct', 'other')),
  contact_name TEXT,
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30 / net 45; direct = 0
  default_signing_fee REAL,                         -- $ per completed signing
  default_print_fee REAL,                           -- $ when you print the package
  default_trip_fee REAL,                            -- $ owed when signer no-shows / late cancel after you travelled
  default_no_sign_fee REAL,                         -- $ owed when signer refuses at the table
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Places: a cache of signing addresses -> ZenSched location ids.
-- Title offices, hospitals, nursing homes, and attorney offices repeat; borrower
-- homes usually do not. normalized_address is the de-dup key: the agent builds it
-- as lowercase(address + city + state + zip) with commas, periods, and '#' removed
-- and whitespace collapsed to single spaces (SQLite cannot collapse whitespace, so
-- the agent does it). The agent looks here FIRST and only calls location_create
-- (geocode, $0.03) on a miss. Hand-tuned pins (location_update) therefore survive
-- for repeat sites. place_label is the ONLY name sent to ZenSched for this
-- address. access_notes is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS places (
  place_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  place_label TEXT,                                 -- sent to ZenSched: 'First American - Kirkland', 'Signing A-2026-0001'
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  access_notes TEXT,                                -- LOCAL ONLY: suite, gate code, parking, 'call from lobby'
  is_repeat_site INTEGER DEFAULT 0,                 -- 1 = office / facility you expect to return to
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Notaries: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row per
-- subcontracted notary with payout_type/payout_value ('flat' = $ per signing,
-- 'percent' = % of the billable total). commission_number is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS notaries (
  notary_id INTEGER PRIMARY KEY AUTOINCREMENT,
  notary_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  commission_number TEXT,                           -- LOCAL ONLY
  commission_expires TEXT,                          -- ISO date
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('flat', 'percent')),
  payout_value REAL,                                -- $ (flat) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Appointments: THE driving table. One row per signing appointment. Each row
-- maps to exactly one ZenSched event (start_date = end_date = the appointment
-- date) and one shift (the appointment window). There is no recurrence.
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- Fees are per-appointment snapshots. Leave them NULL on insert and the
-- fill_appointment_defaults trigger copies the client's default_* fees (else 0).
-- Which fees are billable depends on status; see the billable_appointments view.
--
-- signer_name, signer_phone, access_notes are LOCAL ONLY and never reach ZenSched.
-- outcome, docs_notarized, tracking_no, completion_dc_id come from the Signing
-- Completion Record. checked_in_at / checked_out_at / gps_verified /
-- checkin_distance_m are copied from shift_status once, so "was I on time" and
-- no-show evidence are answered from SQLite for free.
CREATE TABLE IF NOT EXISTS appointments (
  appointment_id INTEGER PRIMARY KEY AUTOINCREMENT,
  appointment_no TEXT UNIQUE,                       -- 'A-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_order_ref TEXT,                            -- the client's order / file / escrow number
  signing_type TEXT NOT NULL DEFAULT 'refinance'
    CHECK (signing_type IN ('purchase', 'refinance', 'seller', 'heloc', 'reverse', 'loan_mod',
                            'gnw', 'apostille', 'hospital', 'jail', 'other')),
  signer_name TEXT,                                 -- LOCAL ONLY
  signer_phone TEXT,                                -- LOCAL ONLY
  signer_count INTEGER DEFAULT 1,
  place_id INTEGER NOT NULL,
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_appointment_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  notary_id INTEGER,                                -- NULL -> settings.default_notary_id (trigger)
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('requested', 'confirmed', 'completed', 'no_show', 'cancelled', 'rescheduled')),
  signing_fee REAL,                                 -- NULL -> client default (trigger)
  print_fee REAL,
  trip_fee REAL,
  no_sign_fee REAL,
  other_fee REAL,                                   -- extra witness, extra signer, late-cancel fee, ...
  scanbacks_required INTEGER DEFAULT 0,
  scanbacks_sent_at TEXT,
  drop_deadline TEXT,                               -- local 'YYYY-MM-DDTHH:MM', last FedEx/UPS drop
  shipping_carrier TEXT,                            -- 'FedEx', 'UPS', 'courier', 'title picks up'
  tracking_no TEXT,
  dropped_at TEXT,                                  -- when the package was dropped
  access_notes TEXT,                                -- LOCAL ONLY: gate code for this visit, 'ring 2B'
  zensched_event_id INTEGER,
  zensched_shift_id INTEGER UNIQUE,
  completion_dc_id INTEGER,                         -- Signing Completion Record submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  outcome TEXT,                                     -- form option key: completed, borrower_no_show, ...
  docs_notarized INTEGER,                           -- from the form
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done (agency mode)
  rescheduled_from INTEGER,                         -- previous appointment_id when this row is the reschedule
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT,
  FOREIGN KEY (notary_id) REFERENCES notaries(notary_id) ON DELETE SET NULL,
  FOREIGN KEY (rescheduled_from) REFERENCES appointments(appointment_id) ON DELETE SET NULL
);

-- Journal index: pointers into your REAL notary journal. One row per notarial
-- act type performed at an appointment ("acknowledgments x 6, jurat x 1").
-- No signer names, no ID numbers, no DOBs, no thumbprints, no loan numbers.
-- notes is for things like 'credible witness used' or 'entry corrected p. 42'.
CREATE TABLE IF NOT EXISTS journal_index (
  entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
  appointment_id INTEGER NOT NULL,
  journal_book TEXT NOT NULL,                       -- 'Book 3', 'eJournal 2026'
  entry_no TEXT NOT NULL,                           -- '0412' or '0412-0418'
  page_no TEXT,
  act_type TEXT NOT NULL
    CHECK (act_type IN ('acknowledgment', 'jurat', 'oath', 'copy_certification', 'signature_witnessing', 'other')),
  act_count INTEGER NOT NULL DEFAULT 1 CHECK (act_count >= 1),
  notes TEXT,                                       -- NO PII
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id) ON DELETE CASCADE
);

-- Mileage: one row per trip. appointment_id is NULL for non-appointment trips
-- (supply run, county clerk). rate and deduction are filled by trigger when
-- left NULL (rate from settings.irs_mileage_rate at the time of the trip).
CREATE TABLE IF NOT EXISTS mileage (
  trip_id INTEGER PRIMARY KEY AUTOINCREMENT,
  appointment_id INTEGER,
  trip_date TEXT NOT NULL,                          -- ISO date
  miles REAL NOT NULL CHECK (miles >= 0),
  from_label TEXT,                                  -- 'Home', 'First American - Kirkland'
  to_label TEXT,
  purpose TEXT,                                     -- 'Signing A-2026-0003 round trip'
  rate REAL,                                        -- $/mile snapshot (trigger)
  deduction REAL,                                   -- miles * rate (trigger)
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per appointment (appointment_no,
-- date, type, fee breakdown, shift id) so the invoice can be regenerated.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a subcontracted notary for one appointment (agency
-- mode). One row per appointment. amount is filled by trigger when left NULL:
-- flat -> notaries.payout_value; percent -> billable_total * payout_value / 100.
-- Never insert a payout for the owner row.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  notary_id INTEGER NOT NULL,
  appointment_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (notary_id) REFERENCES notaries(notary_id) ON DELETE CASCADE,
  FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_places_location ON places(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_appointments_start ON appointments(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_appointments_status_start ON appointments(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_appointments_client ON appointments(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_appointments_place ON appointments(place_id);
CREATE INDEX IF NOT EXISTS idx_appointments_notary ON appointments(notary_id, paid_out);
CREATE INDEX IF NOT EXISTS idx_appointments_event ON appointments(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_appointments_drop ON appointments(status, dropped_at, drop_deadline);
CREATE INDEX IF NOT EXISTS idx_journal_appt ON journal_index(appointment_id);
CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage(trip_date);
CREATE INDEX IF NOT EXISTS idx_mileage_appt ON mileage(appointment_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_notary ON payouts(notary_id, paid);

-- Which fees are billable depends on what happened. This is the single place
-- that rule lives; receivables, invoicing, payouts, and no-show evidence all
-- read billable_total from here rather than re-deriving it.
--   completed  -> signing + print + trip + other   (no_sign_fee is not owed)
--   no_show    -> trip + no_sign                   (you travelled and waited; nothing was signed)
--   cancelled  -> other_fee only                   (a late-cancel / print fee the agent puts in other_fee)
--   requested / confirmed / rescheduled -> 0       (nothing billable yet, or billed on the new row)
CREATE VIEW IF NOT EXISTS billable_appointments AS
SELECT
  a.appointment_id,
  a.appointment_no,
  a.client_id,
  a.client_order_ref,
  a.signing_type,
  a.status,
  date(a.scheduled_start)                          AS appointment_date,
  a.scheduled_start,
  a.notary_id,
  a.signing_fee,
  a.print_fee,
  a.trip_fee,
  a.no_sign_fee,
  a.other_fee,
  CASE a.status
    WHEN 'completed' THEN round(COALESCE(a.signing_fee, 0) + COALESCE(a.print_fee, 0) + COALESCE(a.trip_fee, 0) + COALESCE(a.other_fee, 0), 2)
    WHEN 'no_show'   THEN round(COALESCE(a.trip_fee, 0) + COALESCE(a.no_sign_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(a.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  a.invoiced,
  a.paid_out,
  a.zensched_shift_id,
  a.completion_dc_id
FROM appointments a;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_place_timestamp
AFTER UPDATE ON places
BEGIN
  UPDATE places SET updated_at = datetime('now') WHERE place_id = NEW.place_id;
END;

CREATE TRIGGER IF NOT EXISTS update_notary_timestamp
AFTER UPDATE ON notaries
BEGIN
  UPDATE notaries SET updated_at = datetime('now') WHERE notary_id = NEW.notary_id;
END;

CREATE TRIGGER IF NOT EXISTS update_appointment_timestamp
AFTER UPDATE OF client_id, client_order_ref, signing_type, signer_name, signer_phone, signer_count,
                place_id, scheduled_start, duration_minutes, notary_id, status, signing_fee, print_fee,
                trip_fee, no_sign_fee, other_fee, scanbacks_required, scanbacks_sent_at, drop_deadline,
                shipping_carrier, tracking_no, dropped_at, access_notes, zensched_event_id,
                zensched_shift_id, completion_dc_id, checked_in_at, checked_out_at, gps_verified,
                checkin_distance_m, outcome, docs_notarized, notes, invoiced, paid_out, rescheduled_from
ON appointments
BEGIN
  UPDATE appointments SET updated_at = datetime('now') WHERE appointment_id = NEW.appointment_id;
END;

-- Auto-number appointments: A-2026-0001, A-2026-0002, ... (year of the
-- appointment, sequence = appointment_id, so numbers never collide or reset).
CREATE TRIGGER IF NOT EXISTS number_appointment
AFTER INSERT ON appointments
WHEN NEW.appointment_no IS NULL
BEGIN
  UPDATE appointments
  SET appointment_no = 'A-' || strftime('%Y', NEW.scheduled_start) || '-' || printf('%04d', NEW.appointment_id)
  WHERE appointment_id = NEW.appointment_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- settings.default_appointment_minutes (else 60)
--   notary_id        <- settings.default_notary_id (solo mode: you)
--   *_fee            <- clients.default_*_fee, else 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_appointment_defaults
AFTER INSERT ON appointments
BEGIN
  UPDATE appointments
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_appointment_minutes'),
                                  60),
      notary_id = COALESCE(NEW.notary_id,
                           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_notary_id' AND value IS NOT NULL)),
      signing_fee = COALESCE(NEW.signing_fee, (SELECT default_signing_fee FROM clients WHERE client_id = NEW.client_id), 0),
      print_fee   = COALESCE(NEW.print_fee,   (SELECT default_print_fee   FROM clients WHERE client_id = NEW.client_id), 0),
      trip_fee    = COALESCE(NEW.trip_fee,    (SELECT default_trip_fee    FROM clients WHERE client_id = NEW.client_id), 0),
      no_sign_fee = COALESCE(NEW.no_sign_fee, (SELECT default_no_sign_fee FROM clients WHERE client_id = NEW.client_id), 0),
      other_fee   = COALESCE(NEW.other_fee, 0)
  WHERE appointment_id = NEW.appointment_id;
END;

-- Mileage: snapshot the IRS rate and compute the deduction.
CREATE TRIGGER IF NOT EXISTS fill_mileage_deduction
AFTER INSERT ON mileage
BEGIN
  UPDATE mileage
  SET rate = COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0),
      deduction = round(NEW.miles * COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0), 2)
  WHERE trip_id = NEW.trip_id;
END;

CREATE TRIGGER IF NOT EXISTS recompute_mileage_deduction
AFTER UPDATE OF miles, rate ON mileage
BEGIN
  UPDATE mileage SET deduction = round(NEW.miles * COALESCE(NEW.rate, 0), 2) WHERE trip_id = NEW.trip_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the notary's split when the agent leaves it NULL.
-- flat    -> payout_value (regardless of outcome; the agent overrides for a no-show if the owner wants)
-- percent -> billable_total * payout_value / 100, rounded to cents
-- If the notary has no payout_type the amount stays NULL and payouts_due flags it.
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE n.payout_type
                         WHEN 'flat'    THEN n.payout_value
                         WHEN 'percent' THEN round(b.billable_total * n.payout_value / 100.0, 2)
                       END
                FROM notaries n
                JOIN billable_appointments b ON b.appointment_id = NEW.appointment_id
                WHERE n.notary_id = NEW.notary_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Today's appointments (local date of the computer running the database),
-- open statuses only. One row = one signing to work. start_iso / end_iso carry
-- settings.timezone_offset and are ready for shift_create. The three
-- idempotency keys and the ZenSched names are ready too.
--   needs_location = 1 -> the place has no ZenSched location yet (location_create)
--   needs_shift    = 1 -> the appointment has no ZenSched shift yet (event_create + form_assign + shift_create)
CREATE VIEW IF NOT EXISTS appointments_today AS
SELECT
  a.appointment_id,
  a.appointment_no,
  a.status,
  a.signing_type,
  a.scheduled_start,
  a.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', a.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(a.scheduled_start, '+' || a.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.client_id,
  c.client_name,
  c.client_type,
  a.client_order_ref,
  a.signer_name,
  a.signer_phone,
  a.signer_count,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Signing ' || a.appointment_no)                          AS zensched_location_name,
  CASE a.signing_type
    WHEN 'purchase'  THEN 'Purchase signing'
    WHEN 'refinance' THEN 'Refi signing'
    WHEN 'seller'    THEN 'Seller signing'
    WHEN 'heloc'     THEN 'HELOC signing'
    WHEN 'reverse'   THEN 'Reverse mortgage signing'
    WHEN 'loan_mod'  THEN 'Loan mod signing'
    WHEN 'gnw'       THEN 'General notary work'
    WHEN 'apostille' THEN 'Apostille'
    WHEN 'hospital'  THEN 'Hospital signing'
    WHEN 'jail'      THEN 'Jail signing'
    ELSE 'Notary appointment'
  END || ' ' || a.appointment_no                                                  AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  a.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  a.zensched_event_id,
  a.zensched_shift_id,
  CASE WHEN a.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  a.notary_id,
  n.notary_name,
  n.zensched_worker_id,
  a.signing_fee,
  a.print_fee,
  a.trip_fee,
  a.scanbacks_required,
  a.drop_deadline,
  a.shipping_carrier,
  a.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-appt-' || a.appointment_id                                               AS event_idempotency_key,
  'shift-appt-' || a.appointment_id                                               AS shift_idempotency_key
FROM appointments a
JOIN clients c ON c.client_id = a.client_id
JOIN places p ON p.place_id = a.place_id
LEFT JOIN notaries n ON n.notary_id = a.notary_id
WHERE a.status IN ('requested', 'confirmed')
  AND date(a.scheduled_start) = date('now', 'localtime')
ORDER BY a.scheduled_start;

-- Same columns, next 7 days (today through today + 6).
CREATE VIEW IF NOT EXISTS appointments_upcoming AS
SELECT
  a.appointment_id,
  a.appointment_no,
  a.status,
  a.signing_type,
  a.scheduled_start,
  a.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', a.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(a.scheduled_start, '+' || a.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.client_id,
  c.client_name,
  c.client_type,
  a.client_order_ref,
  a.signer_name,
  a.signer_phone,
  a.signer_count,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Signing ' || a.appointment_no)                          AS zensched_location_name,
  CASE a.signing_type
    WHEN 'purchase'  THEN 'Purchase signing'
    WHEN 'refinance' THEN 'Refi signing'
    WHEN 'seller'    THEN 'Seller signing'
    WHEN 'heloc'     THEN 'HELOC signing'
    WHEN 'reverse'   THEN 'Reverse mortgage signing'
    WHEN 'loan_mod'  THEN 'Loan mod signing'
    WHEN 'gnw'       THEN 'General notary work'
    WHEN 'apostille' THEN 'Apostille'
    WHEN 'hospital'  THEN 'Hospital signing'
    WHEN 'jail'      THEN 'Jail signing'
    ELSE 'Notary appointment'
  END || ' ' || a.appointment_no                                                  AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  a.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  a.zensched_event_id,
  a.zensched_shift_id,
  CASE WHEN a.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  a.notary_id,
  n.notary_name,
  n.zensched_worker_id,
  a.signing_fee,
  a.print_fee,
  a.trip_fee,
  a.scanbacks_required,
  a.drop_deadline,
  a.shipping_carrier,
  a.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-appt-' || a.appointment_id                                               AS event_idempotency_key,
  'shift-appt-' || a.appointment_id                                               AS shift_idempotency_key
FROM appointments a
JOIN clients c ON c.client_id = a.client_id
JOIN places p ON p.place_id = a.place_id
LEFT JOIN notaries n ON n.notary_id = a.notary_id
WHERE a.status IN ('requested', 'confirmed')
  AND date(a.scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY a.scheduled_start;

-- "Don't miss FedEx." Completed signings whose package has not been dropped
-- (or whose scan-backs are still pending) and whose drop deadline is within the
-- next 24 hours or already passed. overdue = 1 means the deadline has passed.
CREATE VIEW IF NOT EXISTS drops_due AS
SELECT
  a.appointment_id,
  a.appointment_no,
  c.client_name,
  a.client_order_ref,
  a.signing_type,
  a.scheduled_start,
  a.drop_deadline,
  a.shipping_carrier,
  a.tracking_no,
  a.dropped_at,
  a.scanbacks_required,
  a.scanbacks_sent_at,
  CASE WHEN a.scanbacks_required = 1 AND a.scanbacks_sent_at IS NULL THEN 1 ELSE 0 END AS scanbacks_pending,
  CASE WHEN a.dropped_at IS NULL THEN 1 ELSE 0 END                                     AS drop_pending,
  CASE WHEN datetime(a.drop_deadline) < datetime('now', 'localtime') THEN 1 ELSE 0 END AS overdue,
  round((julianday(a.drop_deadline) - julianday(datetime('now', 'localtime'))) * 24.0, 1) AS hours_left,
  n.notary_name,
  a.notes
FROM appointments a
JOIN clients c ON c.client_id = a.client_id
LEFT JOIN notaries n ON n.notary_id = a.notary_id
WHERE a.status = 'completed'
  AND a.drop_deadline IS NOT NULL
  AND (a.dropped_at IS NULL OR (a.scanbacks_required = 1 AND a.scanbacks_sent_at IS NULL))
  AND datetime(a.drop_deadline) <= datetime('now', 'localtime', '+24 hours')
ORDER BY a.drop_deadline;

-- Uninvoiced billable work grouped by client, with the billing contact and
-- terms. Completed signings bill their full fees; no-shows bill trip + no-sign
-- only; cancellations bill other_fee only (see billable_appointments).
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  COUNT(b.appointment_id)                          AS appointment_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_show' THEN 1 ELSE 0 END)   AS no_show_count,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.appointment_date)                          AS first_date,
  MAX(b.appointment_date)                          AS last_date
FROM billable_appointments b
JOIN clients c ON c.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_show', 'cancelled')
  AND b.billable_total > 0
GROUP BY c.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients c ON c.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Mileage by calendar month: trips, miles, and the deduction at the snapshot rate.
CREATE VIEW IF NOT EXISTS mileage_by_month AS
SELECT
  strftime('%Y-%m', m.trip_date)                   AS month,
  COUNT(m.trip_id)                                 AS trips,
  SUM(m.miles)                                     AS miles,
  SUM(m.deduction)                                 AS deduction,
  SUM(CASE WHEN m.appointment_id IS NULL THEN m.miles ELSE 0 END) AS non_appointment_miles
FROM mileage m
GROUP BY strftime('%Y-%m', m.trip_date)
ORDER BY month DESC;

-- Agency mode: unpaid sub payouts, one row per appointment, with a running
-- total per notary (notary_total_due). Owner rows never appear.
-- needs_amount = 1 means the notary has no payout_type; ask the owner.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  n.notary_id,
  n.notary_name,
  n.email,
  n.payout_type,
  n.payout_value,
  a.appointment_id,
  a.appointment_no,
  date(a.scheduled_start)                          AS appointment_date,
  a.signing_type,
  a.status,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY n.notary_id)    AS notary_total_due,
  a.invoiced                                       AS client_invoiced
FROM payouts p
JOIN notaries n ON n.notary_id = p.notary_id
JOIN appointments a ON a.appointment_id = p.appointment_id
JOIN billable_appointments b ON b.appointment_id = a.appointment_id
WHERE p.paid = 0
  AND n.is_owner = 0
ORDER BY n.notary_name, a.scheduled_start;

-- Agency mode: completed / no-show appointments worked by a sub that have no
-- payouts row yet. The agent inserts one per row when recording completion.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  a.appointment_id,
  a.appointment_no,
  a.status,
  date(a.scheduled_start)                          AS appointment_date,
  n.notary_id,
  n.notary_name,
  n.payout_type,
  n.payout_value,
  b.billable_total
FROM appointments a
JOIN notaries n ON n.notary_id = a.notary_id AND n.is_owner = 0
JOIN billable_appointments b ON b.appointment_id = a.appointment_id
WHERE a.status IN ('completed', 'no_show')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.appointment_id = a.appointment_id)
ORDER BY a.scheduled_start;

-- What the agent cites when chasing a trip fee: every no-show with the ZenSched
-- shift (GPS-verified arrival) and the Completion Record submission that
-- documents the wait, plus the fee that is owed.
CREATE VIEW IF NOT EXISTS no_show_evidence AS
SELECT
  a.appointment_id,
  a.appointment_no,
  c.client_name,
  c.client_type,
  c.billing_email,
  a.client_order_ref,
  a.signing_type,
  a.scheduled_start,
  strftime('%Y-%m-%dT%H:%M:%S', a.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  n.notary_name,
  a.zensched_event_id,
  a.zensched_shift_id,
  a.completion_dc_id,
  a.checked_in_at,
  a.checked_out_at,
  a.gps_verified,
  a.checkin_distance_m,
  CASE WHEN a.checked_in_at IS NOT NULL AND a.checked_out_at IS NOT NULL
       THEN CAST(round((julianday(a.checked_out_at) - julianday(a.checked_in_at)) * 1440.0) AS INTEGER) END AS minutes_on_site,
  a.outcome,
  a.trip_fee,
  a.no_sign_fee,
  b.billable_total,
  a.invoiced,
  a.notes
FROM appointments a
JOIN clients c ON c.client_id = a.client_id
JOIN places p ON p.place_id = a.place_id
JOIN billable_appointments b ON b.appointment_id = a.appointment_id
LEFT JOIN notaries n ON n.notary_id = a.notary_id
WHERE a.status = 'no_show'
ORDER BY a.scheduled_start DESC;
