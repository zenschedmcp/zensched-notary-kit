# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Lakeside Mobile Notary**, a solo loan signing agent (Dana Reyes) in Kirkland, Washington, Pacific time (`-07:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the borrowers' names and phone numbers, the gate code, the loan number, anything from the notary journal. ZenSched sees `Signing - Elm St`, a street address, `Refi signing A-2026-0001`, and a completion checklist.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Mobile Notary, timezone_offset = -05:00, state = NULL,
    default_notary_id = NULL, default_appointment_minutes = 60,
    default_travel_buffer_minutes = 30, invoice_due_days = 30, invoice_prefix = INV,
    completion_form_id = NULL, irs_mileage_rate = 0.70
sqlite_query:   SELECT * FROM drops_due;            → (none)
sqlite_query:   SELECT * FROM appointments_today;   → (none)
```

## "We're Lakeside Mobile Notary in Kirkland, Washington, Pacific time. It's just me, Dana Reyes, dana@lakesidenotary.example, 425-555-0100. My commission is WA 20431188, expires 2028-03-31. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'Lakeside Mobile Notary' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-07:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'WA' WHERE key = 'state';
```

Agent (first metered call this session, rule 10):

> Saved. Since you're the notary on the phone, I need to invite you to ZenSched as a worker so your signings show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "dana@lakesidenotary.example"
  first_name: "Dana"
  last_name: "Reyes"
  idempotency_key: "worker-dana@lakesidenotary.example"
  → worker_id: 601, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO notaries (notary_name, email, phone, zensched_worker_id, is_owner, commission_number, commission_expires)
  VALUES ('Dana Reyes', 'dana@lakesidenotary.example', '425-555-0100', 601, 1, 'WA 20431188', '2028-03-31');
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_notary_id';
```

The commission number stays in `notaries.commission_number`; ZenSched got a name and an email.

> You're invited; install the app from the email. Your signings will land on your own phone. Next, the Signing Completion Record: it's free to create and every signing comes back with outcome, documents notarized, ID type, scan-back status, tracking number, and a photo of the drop receipt. No signature pad on it, on purpose. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Signing Completion Record"
  idempotency_key: "form-completion-record"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Signing completion", "text": "Complete before you leave. Operational facts only: no ID numbers, dates of birth, loan numbers, or signer names here. Your notary journal is your journal; this is not it."},
  {"type": "select", "label": "Outcome", "identifier": "outcome", "required": true,
   "options": ["Completed", "Borrower no-show", "Signer refused / declined", "Rescheduled on site", "Documents issue - not signed", "Partial - some docs signed"]},
  {"type": "number", "label": "Documents notarized (count)", "identifier": "docs_notarized"},
  {"type": "multi_select", "label": "ID verified by (type only)", "identifier": "id_types",
   "options": ["State driver license", "State ID card", "Passport", "Military ID", "Credible witness", "Personally known", "Other government ID"]},
  {"type": "select", "label": "Scan-backs", "identifier": "scanbacks",
   "options": ["Not required", "Sent", "Pending"]},
  {"type": "text", "label": "Shipping tracking number", "identifier": "tracking_no", "placeholder": "FedEx/UPS number if dropped"},
  {"type": "photo", "label": "Drop-off receipt / package label", "identifier": "drop_receipt", "max_images": 2},
  {"type": "textarea", "label": "Issues or notes for the office", "identifier": "issues"},
  {"type": "textarea", "label": "No-sign / no-show details (time waited, who you called)", "identifier": "no_sign_details",
   "show_if": {"field": "outcome", "op": "not_equals", "value": "completed", "action": "show"}}
]
```

```
  → form_id: 401, fields: [ ...9 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'completion_form_id';
```

> Completion Record created. I'll attach it to every signing automatically. One policy question: you'll usually arrive 10–15 minutes early; want me to allow early check-in and set the check-in radius to 150 m for office parks and hospitals?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 20, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## "Snapdocs just sent this. Book it."

> *Order 4471-K — REFINANCE — Borrower: Maria Torres, (425) 555-0142 — Tue Sep 8, 2026 10:00 AM PT — 1042 Elm St, Kirkland, WA 98033 — Fee: $125.00 + $25.00 print — Scanbacks REQUIRED within 1 hr — FedEx drop by 5:00 PM same day — Loan #: 0081-55231 — Note: gate code 4471, park on street.*

The agent parses: client Snapdocs (signing service), order ref `4471-K`, type refinance, signer Maria Torres + phone, address, Tue 9/8 10:00, fees 125 + 25 print, scan-backs required, FedEx 17:00, gate code. The loan number is **not** stored anywhere; it belongs on the documents and in the journal, not here.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Snapdocs%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_signing_fee, default_print_fee, default_trip_fee, default_no_sign_fee)
  VALUES ('Snapdocs', 'signing_service', 'payables@snapdocs.example', 45, 125, 25, 50, 75);
  → lastInsertRowid = 1
```

> I don't have Snapdocs as a client yet. I've added them as a signing service with $125 signing / $25 print defaults; I've assumed net 45 and a $50 trip fee / $75 no-sign fee, which is typical. Tell me if their terms differ.

```
sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '1042 elm st kirkland wa 98033';   → (none)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, place_label, access_notes, is_repeat_site)
  VALUES ('1042 elm st kirkland wa 98033', '1042 Elm St', 'Kirkland', 'WA', '98033', 'Signing - Elm St', 'Gate code 4471. Park on street.', 0);
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO appointments (client_id, client_order_ref, signing_type, signer_name, signer_phone, signer_count, place_id,
                            scheduled_start, status, signing_fee, print_fee, scanbacks_required, drop_deadline, shipping_carrier)
  VALUES (1, '4471-K', 'refinance', 'Maria Torres', '425-555-0142', 1, 1,
          '2026-09-08T10:00', 'confirmed', 125, 25, 1, '2026-09-08T17:00', 'FedEx');
  → lastInsertRowid = 1
  (triggers fill: appointment_no A-2026-0001, duration_minutes 60, notary_id 1, trip_fee 50, no_sign_fee 75, other_fee 0)

sqlite_query:
  SELECT appointment_no, start_iso, end_iso, zensched_location_name, zensched_event_title, street_address,
         needs_location, zensched_location_id, zensched_worker_id,
         loc_idempotency_key, event_idempotency_key, shift_idempotency_key
  FROM appointments_upcoming WHERE appointment_id = 1;
  → A-2026-0001 | 2026-09-08T10:00:00-07:00 | 2026-09-08T11:00:00-07:00 | Signing - Elm St | Refi signing A-2026-0001
    | 1042 Elm St, Kirkland, WA 98033 | needs_location 1 | NULL | worker 601
    | loc-place-1 | event-appt-1 | shift-appt-1
```

> Putting this on ZenSched costs $0.03 to geocode the address; each signing then costs about $0.35 in GPS check-in/out and reading the completion record ($0.38 total for a new address). OK to proceed for this and future signings?

Owner: *"yes"*

```
location_create:
  name: "Signing - Elm St"
  street_address: "1042 Elm St, Kirkland, WA 98033"
  checkin_radius_m: 100
  idempotency_key: "loc-place-1"
  → location_id: 9101, lat: 47.6815, lng: -122.2087, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE places SET zensched_location_id = 9101 WHERE place_id = 1;

event_create:
  location_id: 9101
  title: "Refi signing A-2026-0001"
  start_date: "2026-09-08"
  end_date:   "2026-09-08"
  idempotency_key: "event-appt-1"
  → event_id: 7101

form_assign:
  form_id: 401
  event_id: 7101
  idempotency_key: "assign-completion-7101"
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0

shift_create:
  event_id: 7101
  worker_id: 601
  start: "2026-09-08T10:00:00-07:00"
  end:   "2026-09-08T11:00:00-07:00"
  idempotency_key: "shift-appt-1"
  → shift_id: 88101, status: "scheduled", forms_installed: [401]

sqlite_execute: UPDATE appointments SET zensched_event_id = 7101, zensched_shift_id = 88101 WHERE appointment_id = 1;
```

Nothing about Maria Torres, her phone, the gate code, or the loan number is in `name`, `title`, or `notes`.

> Booked **A-2026-0001**: refi signing, Snapdocs order 4471-K, Tue Sep 8 10:00–11:00 at Elm St, Kirkland. $125 + $25 print, net 45. Scan-backs required within the hour and FedEx by 5 pm; I'll keep it on the drops list. It's on your phone with the Completion Record attached. Maria's name, number, and the gate code are only on your computer.

## "Lakeview Title emailed: seller package, Wed 9/9 2 pm at their Bellevue office, 500 108th Ave NE Suite 200, Bellevue 98004. File LT-22890, sellers Robert and Anne Kim. $150, they print, no scanbacks, docs stay with escrow. They pay net 30."

Same pattern. The agent does not re-ask about the $0.03 (owner already approved geocoding this session).

```
sqlite_execute: INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_signing_fee)
                VALUES ('Lakeview Title', 'title_escrow', 'ap@lakeviewtitle.example', 30, 150);   → 2
sqlite_query:   SELECT place_id, zensched_location_id FROM places
                WHERE normalized_address = '500 108th ave ne suite 200 bellevue wa 98004';   → (none)
sqlite_execute: INSERT INTO places (normalized_address, address, city, state, zip, place_label, access_notes, is_repeat_site)
                VALUES ('500 108th ave ne suite 200 bellevue wa 98004', '500 108th Ave NE Suite 200', 'Bellevue', 'WA', '98004',
                        'Lakeview Title - Bellevue', 'Suite 200, 2nd floor. Visitor parking P1.', 1);   → 2
sqlite_execute: INSERT INTO appointments (client_id, client_order_ref, signing_type, signer_name, signer_count, place_id, scheduled_start, status, signing_fee, print_fee, shipping_carrier)
                VALUES (2, 'LT-22890', 'seller', 'Robert and Anne Kim', 2, 2, '2026-09-09T14:00', 'confirmed', 150, 0, 'title keeps docs');   → 2
                (trigger: A-2026-0002, 60 min, notary 1, trip_fee 0, no_sign_fee 0)

location_create: name "Lakeview Title - Bellevue", street_address "500 108th Ave NE Suite 200, Bellevue, WA 98004", checkin_radius_m 100, idempotency_key "loc-place-2"
  → location_id 9102, pin_quality "place" (Google Places matched the office building)
sqlite_execute:  UPDATE places SET zensched_location_id = 9102 WHERE place_id = 2;
event_create:    location_id 9102, title "Seller signing A-2026-0002", start_date "2026-09-09", end_date "2026-09-09", idempotency_key "event-appt-2"  → event_id 7102
form_assign:     form_id 401, event_id 7102, idempotency_key "assign-completion-7102"
shift_create:    event_id 7102, worker_id 601, start "2026-09-09T14:00:00-07:00", end "2026-09-09T15:00:00-07:00", idempotency_key "shift-appt-2"  → shift_id 88102
sqlite_execute:  UPDATE appointments SET zensched_event_id = 7102, zensched_shift_id = 88102 WHERE appointment_id = 2;
```

> Booked **A-2026-0002**: seller signing for Lakeview Title, file LT-22890, Wed Sep 9 2:00–3:00 at their Bellevue office. $150, net 30, no scan-backs, no drop. Added Lakeview Title as a client and their office as a repeat site, so the next signing there won't need a new pin.

## Tuesday: the notary does the work

9:52, outside 1042 Elm St, in the ZenSched app: Dana taps **Check in** (GPS: 14 m from the pin, verified, $0.10). Signing runs 55 minutes. **Check out** 10:51 ($0.10). Sends scan-backs from the car at 11:20. Drops the package at the FedEx on Central Way at 12:10, and from the parking lot opens **Signing Completion Record** on the shift: Outcome = Completed; Documents notarized = 6; ID verified by = State driver license; Scan-backs = Sent; Tracking number = 7712 3456 7890; Drop-off receipt = photo of the FedEx receipt; Issues = "Borrower asked about the 3-day rescission, referred to lender." Submits.

## "Torres is done and dropped. 23 miles round trip. Journal book 3, entries 412 to 417, all acknowledgments. Close it out."

```
shift_status: shift_id 88101
  → status "checked_out", actual_in "2026-09-08T09:52:10-07:00", actual_out "2026-09-08T10:51:40-07:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 14 }, { type: "out", gps_verified: true, distance_from_site_m: 11 } ]
(free)
```

> Reading the completion record for A-2026-0001 costs $0.15 because it has the drop-receipt photo. It bills once; after this I answer from the local record. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 401
  event_id: 7101
  limit: 5
  → submissions: [
      { submission_id: 3401, worker_id: 601, event_id: 7101, submitted_at: "2026-09-08 12:14:30",
        data: { outcome: "completed", docs_notarized: 6, id_types: ["state_driver_license"], scanbacks: "sent",
                tracking_no: "7712 3456 7890", issues: "Borrower asked about the 3-day rescission, referred to lender." },
        media: [ { field: "drop_receipt", cdn_url: "https://cdn.zensched.com/m/.../receipt1.jpg" } ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

sqlite_execute:
  UPDATE appointments
  SET status = 'completed', outcome = 'completed', docs_notarized = 6, completion_dc_id = 3401,
      checked_in_at = '2026-09-08T09:52:10-07:00', checked_out_at = '2026-09-08T10:51:40-07:00', gps_verified = 1, checkin_distance_m = 14,
      scanbacks_sent_at = '2026-09-08T12:14', dropped_at = '2026-09-08T12:14', tracking_no = '7712 3456 7890',
      notes = 'Borrower asked about the 3-day rescission, referred to lender.'
  WHERE appointment_id = 1;

sqlite_execute:
  INSERT INTO journal_index (appointment_id, journal_book, entry_no, act_type, act_count)
  VALUES (1, 'Book 3', '0412-0417', 'acknowledgment', 6);

sqlite_execute:
  INSERT INTO mileage (appointment_id, trip_date, miles, from_label, to_label, purpose)
  VALUES (1, '2026-09-08', 23, 'Home', 'Signing - Elm St', 'Signing A-2026-0001 round trip');
  (trigger: rate 0.70, deduction 16.10)
```

`id_types` is not stored; the journal has the ID record. Nothing from the journal beyond "Book 3, 0412–0417, six acknowledgments" is stored. The receipt photo stays on ZenSched; the tracking number and the submission id are enough locally.

> A-2026-0001 closed. Completed, 6 documents notarized, GPS-verified on site 9:52–10:51 (14 m from the pin), scan-backs sent, FedEx dropped 12:14 with receipt photo, tracking 7712 3456 7890. Journal index: Book 3, entries 412–417. Mileage 23 mi, $16.10. $150 is now receivable from Snapdocs, net 45. Nothing left on the drops list.

## Wednesday: seller signing, and a repeat site

Dana checks in at the Lakeview Title office at 13:55 (GPS-verified, 22 m), both sellers sign, Completion Record: Completed, 4 documents, State driver license ×2, Scan-backs = Not required, no tracking, no photo. Checks out 14:48. That evening: *"Close out Lakeview. Book 3, 418 to 421, acknowledgments. 18 miles."* The agent runs the same close-out (shift_status, one $0.05 read, update, journal, mileage). Then:

## "Lakeview wants me back Friday 9/11 at 10 for another seller package, file LT-22917, seller Priya Nair, same office, $150."

```
sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '500 108th ave ne suite 200 bellevue wa 98004';
  → place_id 2, zensched_location_id 9102, 'Lakeview Title - Bellevue'        ← cache hit; no geocode

sqlite_execute: INSERT INTO appointments (client_id, client_order_ref, signing_type, signer_name, signer_count, place_id, scheduled_start, status, signing_fee)
                VALUES (2, 'LT-22917', 'seller', 'Priya Nair', 1, 2, '2026-09-11T10:00', 'confirmed', 150);   → 3  (A-2026-0003)

event_create:  location_id 9102, title "Seller signing A-2026-0003", start_date "2026-09-11", end_date "2026-09-11", idempotency_key "event-appt-3"  → 7103
form_assign:   form_id 401, event_id 7103, idempotency_key "assign-completion-7103"
shift_create:  event_id 7103, worker_id 601, start "2026-09-11T10:00:00-07:00", end "2026-09-11T11:00:00-07:00", idempotency_key "shift-appt-3"  → 88103
sqlite_execute: UPDATE appointments SET zensched_event_id = 7103, zensched_shift_id = 88103 WHERE appointment_id = 3;
```

> Booked **A-2026-0003**: seller signing for Lakeview Title, file LT-22917, Fri Sep 11 10:00–11:00 at their Bellevue office. Reused the existing pin, no geocode fee.

## "Snapdocs order 4502-M, purchase, Thu 9/10 6 pm, borrower Kevin Walsh 206-555-0177, 77 Pine Ct Redmond 98052, $150 + $25 print, scanbacks, FedEx by 8 pm."

Booked as **A-2026-0004** the same way (new place `Signing - Pine Ct`, location 9103, event 7104, shift 88104, `drop_deadline` `2026-09-10T20:00`).

## Thursday: the borrower does not show

Dana checks in at 77 Pine Ct at 17:53 (GPS-verified, 9 m). No answer. Calls the borrower twice, then Snapdocs at 18:15. Waits. At 18:47 fills the Completion Record: Outcome = Borrower no-show; No-sign / no-show details = "Waited 55 min. Called borrower 18:05 and 18:20, voicemail. Called Snapdocs 18:15, ticket 99120. Left." Submits, checks out 18:48.

## "Walsh no-showed. Close it out and get me the trip fee."

```
shift_status: shift_id 88104
  → status "checked_out", actual_in "2026-09-10T17:53:05-07:00", actual_out "2026-09-10T18:48:20-07:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 9 }, { type: "out", gps_verified: true, distance_from_site_m: 12 } ]

form_submissions: form_id 401, event_id 7104, limit 5   ($0.05)
  → [ { submission_id: 3404, submitted_at: "2026-09-10 18:47:10",
        data: { outcome: "borrower_no_show", scanbacks: "pending",
                no_sign_details: "Waited 55 min. Called borrower 18:05 and 18:20, voicemail. Called Snapdocs 18:15, ticket 99120. Left." } } ]

sqlite_execute:
  UPDATE appointments
  SET status = 'no_show', outcome = 'borrower_no_show', completion_dc_id = 3404,
      checked_in_at = '2026-09-10T17:53:05-07:00', checked_out_at = '2026-09-10T18:48:20-07:00', gps_verified = 1, checkin_distance_m = 9,
      scanbacks_required = 0, drop_deadline = NULL,
      notes = 'Waited 55 min. Called borrower 18:05 and 18:20, voicemail. Called Snapdocs 18:15, ticket 99120. Left.'
  WHERE appointment_id = 4;

sqlite_execute: INSERT INTO mileage (appointment_id, trip_date, miles, from_label, to_label, purpose)
                VALUES (4, '2026-09-10', 31, 'Home', 'Signing - Pine Ct', 'Signing A-2026-0004 round trip (no-show)');

sqlite_query: SELECT * FROM no_show_evidence WHERE appointment_id = 4;
  → A-2026-0004 | Snapdocs | 4502-M | purchase | 2026-09-10T18:00 | 77 Pine Ct, Redmond, WA 98052
    | shift 88104 | dc 3404 | in 17:53:05 | out 18:48:20 | gps 1 | 9 m | 55 min on site
    | trip_fee 50 | no_sign_fee 75 | billable_total 125 | invoiced 0
```

`signing_fee` and `print_fee` are still on the row but `billable_appointments` bills only trip + no-sign for a no-show: $125. Because the drop deadline was cleared, A-2026-0004 is not on `drops_due`.

> A-2026-0004 recorded as a no-show. Billable: $50 trip + $75 no-sign = $125 to Snapdocs. Here's the note for their portal:
>
> ```
> Order 4502-M — Borrower no-show, Thu Sep 10 2026, 6:00 PM appointment.
> Notary arrived 5:53 PM, GPS-verified on site (9 m from the address), waited 55 minutes (departed 6:48 PM).
> Borrower called 6:05 PM and 6:20 PM, voicemail both times. Snapdocs support called 6:15 PM, ticket 99120.
> Requesting trip fee $50 + no-sign fee $75 per fee schedule. Reference: Lakeside Mobile Notary A-2026-0004.
> ```

## "Saturday I've got a power of attorney at Evergreen Hospital, room 412, 11 am. Daughter Linda Park is arranging it, 425-555-0190, pays me direct, $75 plus $40 travel. Two witnesses she's bringing."

General notary work at a hospital: `signing_type = 'hospital'` (the location) with the act recorded in the journal index later. Direct client, paid at the table.

```
sqlite_execute: INSERT INTO clients (client_name, client_type, contact_phone, payment_terms_days)
                VALUES ('Direct - Park family', 'direct', '425-555-0190', 0);   → 3
sqlite_query:   SELECT place_id, zensched_location_id FROM places
                WHERE normalized_address = '12040 ne 128th st kirkland wa 98034';   → (none)
sqlite_execute: INSERT INTO places (normalized_address, address, city, state, zip, place_label, access_notes, is_repeat_site)
                VALUES ('12040 ne 128th st kirkland wa 98034', '12040 NE 128th St', 'Kirkland', 'WA', '98034',
                        'Evergreen Hospital - Kirkland', 'Main entrance, ask for 4th floor. Garage B validates.', 1);   → 3
sqlite_execute: INSERT INTO appointments (client_id, signing_type, signer_name, signer_phone, signer_count, place_id, scheduled_start, duration_minutes, status, signing_fee, trip_fee, access_notes)
                VALUES (3, 'hospital', 'Linda Park (for patient)', '425-555-0190', 1, 3, '2026-09-12T11:00', 45, 'confirmed', 75, 40, 'Room 412');   → 5  (A-2026-0005)

location_create: name "Evergreen Hospital - Kirkland", street_address "12040 NE 128th St, Kirkland, WA 98034", checkin_radius_m 100, idempotency_key "loc-place-3"
  → location_id 9104, pin_quality "place"
sqlite_execute:  UPDATE places SET zensched_location_id = 9104 WHERE place_id = 3;
event_create:    location_id 9104, title "Hospital signing A-2026-0005", start_date "2026-09-12", end_date "2026-09-12", idempotency_key "event-appt-5"  → 7105
form_assign:     form_id 401, event_id 7105, idempotency_key "assign-completion-7105"
shift_create:    event_id 7105, worker_id 601, start "2026-09-12T11:00:00-07:00", end "2026-09-12T11:45:00-07:00", idempotency_key "shift-appt-5"  → 88105
sqlite_execute:  UPDATE appointments SET zensched_event_id = 7105, zensched_shift_id = 88105 WHERE appointment_id = 5;
```

The room number is in `appointments.access_notes`; the patient's name is not stored at all (Linda is the contact). ZenSched sees `Evergreen Hospital - Kirkland`, which is a public place, and `Hospital signing A-2026-0005`.

> Booked **A-2026-0005**: hospital POA, Sat Sep 12 11:00–11:45, Evergreen Kirkland, room 412 (that's only on your computer). $75 + $40 travel, paid direct. Since the campus is big, the 150 m radius you set should cover the garage; tell me if the check-in fails and I'll move the pin to the main entrance for next time.

Saturday: check-in 10:48 at the hospital (GPS-verified, 61 m from the pin, inside the 150 m policy radius), signing done, Completion Record: Completed, 1 document, State driver license + Credible witness, scan-backs Not required. Check-out 11:32. Linda pays $115 by Zelle at the bedside.

## "Close out the hospital. Book 3 entry 422, one acknowledgment, two credible witnesses noted. 14 miles. She paid me $115 on the spot."

```
shift_status: 88105 → in 10:48:00-07:00, out 11:32:15-07:00, gps in 61 m verified
form_submissions: form_id 401, event_id 7105, limit 5   ($0.05)
  → [ { submission_id: 3405, data: { outcome: "completed", docs_notarized: 1, id_types: ["state_driver_license", "credible_witness"], scanbacks: "not_required" } } ]

sqlite_execute: UPDATE appointments SET status = 'completed', outcome = 'completed', docs_notarized = 1, completion_dc_id = 3405,
                checked_in_at = '2026-09-12T10:48:00-07:00', checked_out_at = '2026-09-12T11:32:15-07:00', gps_verified = 1, checkin_distance_m = 61
                WHERE appointment_id = 5;
sqlite_execute: INSERT INTO journal_index (appointment_id, journal_book, entry_no, act_type, act_count, notes)
                VALUES (5, 'Book 3', '0422', 'acknowledgment', 1, 'Credible witnesses used (2)');
sqlite_execute: INSERT INTO mileage (appointment_id, trip_date, miles, from_label, to_label, purpose)
                VALUES (5, '2026-09-12', 14, 'Home', 'Evergreen Hospital - Kirkland', 'Signing A-2026-0005 round trip');

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'), date('now', 'localtime', '+0 days'), SUM(b.billable_total),
         json_group_array(json_object('appointment_no', b.appointment_no, 'date', b.appointment_date, 'type', b.signing_type, 'status', b.status,
                                      'order_ref', b.client_order_ref, 'signing_fee', b.signing_fee, 'print_fee', b.print_fee, 'trip_fee', b.trip_fee,
                                      'no_sign_fee', b.no_sign_fee, 'other_fee', b.other_fee, 'billable', b.billable_total, 'shift_id', b.zensched_shift_id))
  FROM billable_appointments b WHERE b.invoiced = 0 AND b.client_id = 3 AND b.billable_total > 0 GROUP BY b.client_id;
sqlite_execute: UPDATE appointments SET invoiced = 1 WHERE invoiced = 0 AND client_id = 3 AND status IN ('completed', 'no_show', 'cancelled');
sqlite_execute: UPDATE invoices SET paid = 1, paid_date = '2026-09-12', sent_date = '2026-09-12' WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001, $115, paid
```

> A-2026-0005 closed: completed, 1 acknowledgment with two credible witnesses (journal Book 3, entry 422), GPS-verified 10:48–11:32. Recorded INV-2026-0001 for $115 and marked it paid. 14 miles, $9.80.

## Month end: "Invoice Snapdocs and Lakeview, and tell me who owes me what."

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Snapdocs       | signing_service | payables@snapdocs.example   | net 45 | 2 appts (1 completed, 1 no-show) | 275.00 | 2026-09-08 .. 2026-09-10
    Lakeview Title | title_escrow    | ap@lakeviewtitle.example    | net 30 | 2 appts (2 completed)            | 300.00 | 2026-09-09 .. 2026-09-11

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('appointment_no', b.appointment_no, 'date', b.appointment_date, 'type', b.signing_type, 'status', b.status,
                                      'order_ref', b.client_order_ref, 'signing_fee', b.signing_fee, 'print_fee', b.print_fee, 'trip_fee', b.trip_fee,
                                      'no_sign_fee', b.no_sign_fee, 'other_fee', b.other_fee, 'billable', b.billable_total, 'shift_id', b.zensched_shift_id))
  FROM billable_appointments b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0 GROUP BY b.client_id;
sqlite_execute: UPDATE appointments SET invoiced = 1 WHERE invoiced = 0 AND client_id = 1 AND status IN ('completed', 'no_show', 'cancelled');
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices WHERE invoice_id = last_insert_rowid();
  → INV-2026-0002 | 2026-09-30 | 2026-11-14 | 275.00        (net 45; number assigned by trigger)

(same three statements for client 2 → INV-2026-0003 | 2026-09-30 | 2026-10-30 | 300.00)
```

> Here's the Snapdocs invoice, ready for their payables portal:
>
> ```
> Lakeside Mobile Notary
> Invoice INV-2026-0002
> To: Snapdocs (payables@snapdocs.example)
> Date: Sep 30, 2026    Due: Nov 14, 2026 (net 45)
>
>   A-2026-0001  Tue Sep 8   Refinance, order 4471-K      Signing $125.00 + print $25.00       $150.00
>   A-2026-0004  Thu Sep 10  Purchase, order 4502-M       Trip fee $50.00 + no-sign $75.00     $125.00
>                            Borrower no-show; notary GPS-verified on site 5:53–6:48 PM, ticket 99120
>
> Total due: $275.00
> ```
>
> And Lakeview Title, INV-2026-0003, $300 (A-2026-0002 and A-2026-0003, $150 each), due Oct 30. No signer names, loan numbers, or property addresses on either; the order refs identify the files. Say "sent" when they're submitted.

```
sqlite_query: SELECT * FROM invoices_outstanding;
  → INV-2026-0003 | Lakeview Title | due 2026-10-30 | 300.00 | days_past_due -30 | current
    INV-2026-0002 | Snapdocs       | due 2026-11-14 | 275.00 | days_past_due -45 | current
```

> Outstanding: $575, all current. Nothing overdue. I'll flag Lakeview after Oct 30 and Snapdocs after Nov 14 if they haven't paid.

## "Mileage for September?"

```
sqlite_query: SELECT * FROM mileage_by_month;
  → 2026-09 | 4 trips | 86 miles | 60.20 | 0 non-appointment miles
```

> September: 4 trips, 86 miles, $60.20 at the $0.70 IRS rate. All of it tied to signings A-2026-0001, -0002, -0004, and -0005.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Borrowers' and sellers' names and phone numbers, gate code, room number | SQLite **only** (`appointments.signer_name`, `signer_phone`, `access_notes`, `places.access_notes`) | Signer PII never reaches ZenSched |
| Loan number, ID numbers, DOBs, thumbprints, signatures | **Nowhere in this kit** | They belong in the notary journal and on the documents |
| Journal pointers (Book 3, entries 412–422) with act type and count | SQLite (`journal_index`) | Finds the entry later without copying it |
| Dana's commission number and expiry | SQLite (`notaries`) | Local roster; ZenSched holds only the worker account |
| Snapdocs, Lakeview Title, the Park family: terms, billing email, default fees | SQLite (`clients`) | Billing; ZenSched does not model clients or fees |
| Each address, normalized, with its ZenSched location id and repeat-site flag | SQLite (`places`) | De-dup cache; repeat offices skip the $0.03 geocode and keep their pin |
| `Signing - Elm St`, `Lakeview Title - Bellevue`, `Evergreen Hospital - Kirkland` and their street addresses and GPS pins | ZenSched (ID in `places`) | Needed for geofenced check-in; labels carry no signer identity |
| One single-day event per appointment (`Refi signing A-2026-0001`, ...) | ZenSched (ID in `appointments`) | Shifts hang off events; title is type + number only |
| One shift per appointment (the 60-minute window) | ZenSched (ID in `appointments`) | Live schedule and push notification; never copied |
| Dana as a ZenSched worker | ZenSched (ID in `notaries`, `is_owner = 1`) | Solo mode: the owner is the notary on the phone |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `appointments.checked_in_at` / `checked_out_at` / `gps_verified` / `checkin_distance_m` | Proof of on-time arrival and no-show evidence, answered from SQLite for free afterwards |
| The Signing Completion Record form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field |
| Five Completion Record submissions | ZenSched (originals); outcome, count, tracking, notes, `completion_dc_id` in `appointments` | Read once (metered), then answered from SQLite; `id_types` not stored |
| Check-in policy (150 m radius, 20 min early check-in, 15 min check-out reminder) | ZenSched (policy 0) | Radius is enforced by the policy, not per location |
| Fees per appointment, billable totals, three invoices, aging | SQLite (`appointments`, `billable_appointments`, `invoices`, `invoices_outstanding`) | Receivables from signing services and title companies |
| Mileage and deductions | SQLite (`mileage`) | Tax record at the snapshot rate |
| Sub payouts | SQLite (`payouts`) | Not used this week (solo); agency mode only |
