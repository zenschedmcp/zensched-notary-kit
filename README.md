# ZenSched Mobile-Notary Reference Kit

A copy-pasteable setup for a solo mobile notary / loan signing agent (NSA), or a 2–5 notary micro-agency that dispatches subcontracted notaries, that wants an AI assistant to run appointment intake, GPS-verified arrival at each signing, a completion record with the drop-receipt photo, a journal index, mileage, receivables from signing services and title companies, and sub payouts. ZenSched handles the phone app, the GPS check-in at each signing address, the one-off event and shift per appointment, and the Signing Completion Record. A small local database on your computer holds your clients, the addresses you have been to, your appointments (with the signers' names and phone numbers), the index into your journal, mileage, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste a confirmation email into your AI assistant ("Snapdocs just sent this, book it"), ask "what's today", "was I on time at the Kim signing", "close out today", "invoice Snapdocs", "who owes me money", "mileage for September", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not your notary journal — read this first

**What this kit is:** a way for a notary to get every signing onto their phone from a pasted confirmation, prove GPS-verified on-time arrival at each one, record what happened (completed, no-show, documents notarized, scan-backs, tracking number, drop receipt), and turn those records into invoices, receivables follow-up, mileage totals, and sub payouts with an AI assistant doing the clerical work.

**What it is not:**

- **It is not a notary journal, and it does not replace one.** Most states require you to keep a journal of notarial acts; several (California among them) prescribe a bound book or a state-approved electronic journal, and the entries (signer name, ID type *and number*, signature, thumbprint where required, fee) are governed by state law. Nothing in this kit records those things. The local database has a `journal_index` table that stores **where** the entry is in your real journal (book label, entry number, page) plus the act type and count, so you can find it later. It never stores ID numbers, SSNs, dates of birth, loan numbers, or thumbprints, and `SKILL.md` forbids the AI from accepting them.
- **ZenSched never receives signer information.** Signer names, phone numbers, gate codes, and room numbers live only in the local database. ZenSched sees a place label (`Lakeview Title - Bellevue`, or `Signing - Elm St` for a home), the street address for the GPS pin, an event title made of the signing type and your appointment number (`Refi signing A-2026-0001`), and the Completion Record, which asks for ID *type* only. You are still responsible for your own privacy obligations (the local database, your email, your phone); this kit narrows what a third party sees, it does not make you compliant by itself.
- **It does not perform or witness notarial acts, does not verify identity, and is not a RON platform.** The Completion Record has no signature pad, on purpose: on ZenSched a signature field replaces the Submit button, and a signature on an ops form invites confusion with the notarial act.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof of arrival, a clean close-out per signing, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per signing address, cached locally so repeat offices are created once; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one single-day event per appointment)
- Shifts (one per appointment: the signing window, 60 minutes by default, with a push notification to the notary)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Signing Completion Record form (outcome, documents notarized, ID type, scan-backs, tracking number, drop-receipt photo, notes) and every submission

**Local SQLite database (`notary-ops.db`, on your computer):**

- Clients: signing services, title/escrow, lenders, attorneys, direct signers, with payment terms and default fees
- Places: every address you have been sent to, normalized, with its ZenSched location id and access notes (suite, gate code, parking) — **access notes never leave your computer**
- Notaries: you (and your subs), commission number and expiry — **never leave your computer**; payout split per sub
- Appointments: order ref, signing type, signer name and phone (**never leave your computer**), place, time, fees, scan-back and drop deadlines, outcome, the ZenSched event/shift/submission ids, GPS arrival stamps copied once
- Journal index: pointers into your real journal (book, entry, page, act type, count); no PII
- Mileage with the IRS rate snapshot and deduction
- Invoices per client with aging; payouts per sub per signing
- Your settings (timezone, state, default notary, default appointment length, invoice terms and prefix, mileage rate, Completion Record form id)

**Never duplicated:** the live schedule, punches, and receipt photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on time", "did it fund", and "who owes me" without paying to re-read records.

### Privacy note

Everything that identifies a signer lives only in the local database: `appointments.signer_name`, `signer_phone`, `access_notes`, and `places.access_notes`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). Loan numbers, ID numbers, dates of birth, and thumbprints are not stored anywhere in this kit; they belong on the documents and in your journal. The Completion Record form itself tells the notary not to write them in it. Your commission number is in the local roster only.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `notary-ops.db` on your computer.

When you paste a confirmation, the AI extracts the client, order number, signing type, signer, address, time, and fees; adds the client if new; looks the address up in your `places` cache (a title office you have been to before is reused, a new address is geocoded once); saves the appointment with an appointment number like `A-2026-0001`; creates a single-day event and a shift on ZenSched with the Completion Record attached; and confirms in one line. You see the signing on your phone, check in at the door (GPS-verified), do the signing, check out, drop the package, and fill in the Completion Record with the tracking number and a photo of the receipt. In the evening you say "close out today" and the AI pulls your verified arrival times and the records, updates each appointment, asks for the journal entry numbers and miles, and tells you what is now receivable. "Invoice Snapdocs" produces a plain-text invoice under their terms; "who owes me money" ages what is open; "mileage for September" totals the month. In agency mode, "what do I owe Marcus" lists his split per signing. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\notary-ops`
- Mac: `/Users/yourname/notary-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain signer names and phone numbers; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\notary-ops.db` (Windows) or `/notary-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "notary-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/notary-ops/notary-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\notary-ops\\notary-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Mobile Notary" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my notary-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 54 statements and confirm the tables exist. The `notary-ops.db` file now exists in your folder with default settings (60-minute appointments, net 30, $0.70/mile) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 notary-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Lakeside Mobile Notary in Kirkland, Washington, Pacific time. It's just me, Dana Reyes, dana@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the notary on the phone; $0.25, one time), creates the Signing Completion Record form on ZenSched (free), and saves the form id so every signing gets it automatically. In agency mode you then say "add my sub Marcus Bell, marcus@example.com, I pay him $90 a signing" for each notary you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's policy, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its driveway are covered as is. For hospitals, office parks, and jails where you park a long way from the entrance, ask the AI to "set the check-in radius to 150 m" or 300 m (`policy_update`), or to move the pin onto the entrance for a repeat site (`location_update`, free; the `places` cache keeps it). Notaries arrive early: ask for "allow check-in 20 minutes before the shift" (`checkin_slack_min`). `remote_checkin` turns GPS verification off for every signing and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat address), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Completion Record ($0.05, or $0.15 when it has the drop-receipt photo; each record is billed once, ever). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

A signing at a new address costs $0.03 + $0.20 + $0.15 = **$0.38**; a signing at a repeat office costs $0.35. Twenty signings a month is about $7.50. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste a Snapdocs / Notary Dash / title-company confirmation) "Book it."
- "What's today?" / "What's this week?"
- "Was I on time at the Kim signing?"
- "Close out today. Torres: Book 3, entries 412 to 417, all acknowledgments, 23 miles."
- "Walsh no-showed. Get me the trip fee."
- "What do I still have to drop?"
- "The 10 o'clock moved to 1." / "Lakeview moved the Nair signing to Monday."
- "Cancel the Pine Court signing; they owe a $35 print fee."
- "Invoice Snapdocs." / "Invoice everyone."
- "Who owes me money?"
- "Snapdocs paid INV-2026-0002."
- "Mileage for September?"
- Agency: "Add my sub Marcus Bell, marcus@example.com, $90 a signing." / "Give the Thursday 6 pm to Marcus." / "What do I owe Marcus?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Snapdocs" records the invoice in your database (number, date, due date under that client's terms, total, which appointments with their fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the signing service's payables portal, with a line per appointment (your appointment number, date, type, their order ref, fees) and, for a no-show, the GPS-verified arrival and wait. It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry a signer's name, a loan number, or a property address; the order ref identifies the file to them. When the client pays, tell the AI ("Snapdocs paid INV-2026-0002") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per signing, not by the hour. Each sub has a split (`$90 flat` or `70%` of what the client is billed for that appointment). When a sub's signing is closed out, a payout row is created with the amount; "what do I owe Marcus" lists his unpaid signings and the total, and "paid Marcus" marks them. Your own signings never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record for your own books, ZenSched's `timesheet_export(mode="hours")` is free; the kit does not use timesheets for pay.

## Mobile app for notaries

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [App Store](https://apps.apple.com/us/app/zensched/id6800081657)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your signings appear as they are booked. Each one shows the address and time; you check in on arrival (GPS-verified), check out when you leave, and fill in the Signing Completion Record, including a photo of the FedEx/UPS receipt once you have dropped the package. Subs get the same email when you add them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `notary-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -08:00 in settings" (use your own offset; Pacific is -07:00 in summer, -08:00 in winter) |
| Signing not on my phone | Booked locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's signings on my phone"; the AI finishes the intake steps |
| Check-in not GPS-verified at a hospital / office park | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`), or "move the pin to the main entrance" (`location_update`, free; the cached place keeps it), or `location_refine` ($0.10) |
| App would not let me check in 15 minutes early | Early check-in window too small | "Allow check-in 20 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Completion Record not on the phone | Form not assigned to that appointment's event before the shift was created | "Attach the Completion Record to A-2026-0004" (`form_assign`), then cancel and recreate the shift |
| "No-sign details" shows even when Outcome is Completed | Conditional fields are web-only on ZenSched | Harmless; leave it blank |
| AI refuses to store a loan number or ID number | Working as intended | That goes in your journal and on the documents |
| Same title office geocoded twice | Address typed differently (suite on a new line, "Ave" vs "Avenue") | Tell the AI it is the same place; it merges the `places` rows and keeps one location |
| Appointment moved to another day fails on `shift_update` | Events are single-day | The AI cancels the shift and creates a new appointment (`rescheduled_from`) with its own event; ask it to |
| Mileage deduction looks off | `irs_mileage_rate` still last year's | "Set the mileage rate to 0.72"; existing trips keep their snapshot |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for clients, places, roster, appointments (including all signer PII), the journal index, mileage, billing, and payouts; each side stores only the other's IDs, plus a per-appointment summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (signer columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–2; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **One-off appointments, not recurring routes.** The first three kits in this series (lawn, pet care, home care) revolve around a `visit_schedule` template expanded weekly into shifts on a per-site event rolled every 60 days. Notary work is a different address almost every time, so there is no recurrence table and no event roll. `appointments` is the driving table; each row maps to exactly one `event_create(location_id, title, start_date=<date>, end_date=<date>, idempotency_key="event-appt-{appointment_id}")` and one `shift_create(event_id, worker_id, start, end, idempotency_key="shift-appt-{appointment_id}")`, with `form_assign(form_id, event_id=...)` in between so the shift installs the form on the phone. The 60-day event cap is irrelevant because every event is one day.
- **`places` is an address de-dup cache.** `places.normalized_address` is `UNIQUE`; the agent normalizes (lowercase, strip `,` `.` `#`, collapse whitespace, include city/state/zip) and looks it up before any `location_create`. A hit reuses `zensched_location_id`, which saves the $0.03 geocode and, more importantly, preserves any hand-tuned pin (`location_update`) for a title office, hospital, or jail the notary returns to. Normalization is done by the agent rather than a trigger because SQLite cannot collapse whitespace cleanly and a partially-normalized trigger would give confusing `UNIQUE` errors. `is_repeat_site` is a hint for labelling (`<client> - <city>` for offices, `Signing - <street>` for homes).
- **Solo mode is the default; agency mode is additive.** The owner is invited as a ZenSched worker (`worker_invite` with their own email, $0.25) and stored on `notaries` with `is_owner = 1`; `settings.default_notary_id` points at that row and the `fill_appointment_defaults` trigger assigns it when `notary_id` is left NULL. Subs are further `notaries` rows with `payout_type` `CHECK IN ('flat', 'percent')` and `payout_value`. `payouts_due` and `payouts_missing` exclude `is_owner = 1`.
- **Receivables and payouts, not timesheets.** Notaries are paid per signing by the client, often net 30–45, so the money model is per-appointment fees → `billable_appointments` → `invoices` with the client's `payment_terms_days` → `invoices_outstanding` aging. Subs are paid per signing (split), so `payouts` is per appointment, not hourly. `timesheet_export` appears in `SKILL.md` only as an optional free hours record.
- **`billable_total` is computed in a view, not stored.** The fee columns on `appointments` (`signing_fee`, `print_fee`, `trip_fee`, `no_sign_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults when left NULL. Which of them are owed depends on `status`, and that rule lives once, in `billable_appointments`: `completed` → signing + print + trip + other; `no_show` → trip + no_sign; `cancelled` → `other_fee` only (the agent puts a late-cancel or print fee there); everything else → 0. `receivables_by_client`, the invoice `INSERT ... SELECT`, `payouts_due`, `no_show_evidence`, and the `fill_payout_amount` trigger all read from that view. Storing it would have meant a second trigger on every fee/status change and a place for the two to disagree.
- **`appointment_no`** is assigned by trigger as `A-{YYYY of scheduled_start}-{appointment_id:04d}` when left NULL; an explicit value is kept. `invoices.invoice_number` is `{prefix}-{YYYY}-{invoice_id:04d}` the same way.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-08T10:00`, `CHECK`-constrained to reject a trailing offset or `Z`). `appointments_today` / `appointments_upcoming` emit `start_iso` and `end_iso` by appending `settings.timezone_offset`, with `end_iso` via `datetime(..., '+N minutes')`. `drop_deadline` uses the same local form; `drops_due` normalizes with `datetime()` before comparing (a `T` separator sorts after a space, so raw string comparison would be wrong). Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer, whose clock is in the business's time zone; `date('now')` would be UTC and would roll "today" over at 4–5 pm Pacific.
- **`status` and `outcome` are separate.** `outcome` is the raw Completion Record option key (`completed`, `borrower_no_show`, `signer_refused___declined`, `rescheduled_on_site`, `documents_issue___not_signed`, `partial___some_docs_signed`); `status` is the billing state (`requested | confirmed | completed | no_show | cancelled | rescheduled`) the agent derives from it. Refused and documents-issue outcomes map to `no_show` because they bill the same way (trip + no-sign).
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field, and a signature capture on an operations form invites confusion with the notarial act. The record therefore submits with a normal button. `drop_receipt` is a `photo` field (`max_images: 2`); a submission with a photo bills $0.15 instead of $0.05.
- **GPS stamps are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m` are filled from `shift_status` at close-out so "was I on time" and `no_show_evidence.minutes_on_site` are answered locally. ZenSched remains the original.
- **`journal_index`** has `act_type` `CHECK IN ('acknowledgment', 'jurat', 'oath', 'copy_certification', 'signature_witnessing', 'other')` and `act_count >= 1`. It cascades from `appointments`. There is intentionally no column for anything a journal statute requires; the table's job is to find the entry, not to be it.
- **`mileage`** snapshots `rate` from `settings.irs_mileage_rate` (seeded `0.70`, the 2025 IRS business rate; update yearly) and computes `deduction` by trigger on insert and on update of `miles`/`rate`. `appointment_id` is nullable for supply runs.
- **Reschedules.** Same day → `shift_update` and update `scheduled_start`. Different day → the single-day event cannot move, so `shift_cancel`, mark the row `rescheduled`, insert a new row with `rescheduled_from` (self-referencing FK, `ON DELETE SET NULL`), and create a new event/shift. Only the new row bills.
- `appointments.zensched_shift_id`, `notaries.zensched_worker_id`, `payouts.appointment_id`, and `places.normalized_address` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to appointments, journal entries, invoices, and payouts and sets `mileage.appointment_id` NULL; deleting a notary sets `appointments.notary_id` NULL and removes their payouts; `places` is `ON DELETE RESTRICT` while appointments reference it.

**Signing Completion Record form.** Created once with `form_create(title, fields_json, idempotency_key="form-completion-record")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's form validator. Every field carries an explicit `identifier` so submission `data` keys are stable (`outcome`, `docs_notarized`, `id_types`, `scanbacks`, `tracking_no`, `drop_receipt`, `issues`, `no_sign_details`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters), which is why `Signer refused / declined` comes back as `signer_refused___declined`; the last outcome label is `Partial - some docs signed` rather than "...documents signed" because the longer label would have been truncated to `partial___some_documents_signe`. One `show_if` references `outcome` with value `completed`; ZenSched documents conditionals as web-only, so the phone may show "No-sign / no-show details" unconditionally. Attaching is `form_assign(form_id, event_id=...)` per appointment, which resolves event → brand → policy and installs the form on the phone for the subsequent `shift_create`.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-place-{place_id}`
- event: `event-appt-{appointment_id}`
- shift: `shift-appt-{appointment_id}` (a notary swap on the same appointment appends `-2`)
- assignment: `assign-completion-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-completion-record`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T10:00:00-07:00`), never `Z`. The views build these strings so the agent does not have to. `checked_in_at` / `checked_out_at` keep the offset ZenSched returns so `julianday` arithmetic in `no_show_evidence` is exact.

**Metered reads.** `form_submissions(form_id, event_id=...)` is the natural per-appointment read because every appointment has its own event; `form_export` covers a week or month in one call. Both bill $0.05 per submission ($0.15 with a photo), once per submission ever. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. `checkin_slack_min` matters for notaries, who arrive early. The kit's example sets 150 m / 20 min / 15 min check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite. Any SQLite MCP server with read and write tools will work; adjust the tool names in `SKILL.md`.

**Schema test.** The schema was verified by splitting the file into its 54 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 9 tables, 10 views, and 10 triggers present; every view on an empty database; `places.normalized_address`, `notaries.zensched_worker_id`, `appointments.zensched_shift_id`, and `payouts.appointment_id` `UNIQUE`; the `number_appointment` trigger (`A-YYYY-0001`, explicit number kept); `fill_appointment_defaults` (duration from settings and following a changed setting, notary from `default_notary_id`, fees from client defaults, else 0, explicit fee kept); `appointments_today` / `appointments_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 60/90-minute durations, `needs_location` when the place has no location id, `needs_shift`, the three idempotency keys, `zensched_event_title` containing type + number and no signer name, `zensched_location_name` from `place_label`, worker id from the default notary, 7-day window bounds, cancelled excluded); `updated_at` triggers on appointments and clients; `drops_due` (includes a completed appointment with the deadline 6 h out, excludes one already dropped, excludes a 3-day deadline, includes dropped-but-scan-backs-pending, `overdue` and negative `hours_left` after the deadline, empty after the drop); `billable_appointments` for completed (200 = signing + print + trip + other, no-sign excluded), no-show (125 = trip + no-sign), cancelled (`other_fee` only), and confirmed (0); `receivables_by_client` totals, counts, and terms per client and the drop-off after invoicing; `no_show_evidence` joining shift id, submission id, `minutes_on_site` (55), billable, and client; invoice numbering, total, due date = +45 days from the client's terms, `line_items` JSON with fee breakdown; `invoices_outstanding` aging buckets `90+` / `60` / `30` / `current` with `days_past_due` and paid excluded; the mileage trigger (23.4 × 0.70 = 16.38, explicit rate kept, nullable appointment, recompute on update) and `mileage_by_month`; `payouts_missing`; `payouts_due` math for flat (90) and percent (70% of 200 = 140), `needs_amount` for a notary without a split, owner exclusion, paid rows dropping out; `journal_index` insert; `rescheduled_from`; every `CHECK` (client type, payout type, signing type, status, `scheduled_start` format with offset and `Z` rejected, duration range, act type, act count, miles); foreign keys rejecting an unknown client, `RESTRICT` on places, `SET NULL` / cascade on notary delete, and the full cascade on client delete. 77 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
