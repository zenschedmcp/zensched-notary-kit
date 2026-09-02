# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not your notary journal" section of `README.md`. Short version: this kit points at your journal, it is not one; signer names and phone numbers stay on your computer; ZenSched only ever sees a place label, an address, and a completion checklist.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\notary-ops` (Windows) or `/Users/yourname/notary-ops` (Mac). Note the full path. It will hold signer names and phone numbers, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\notary-ops\\notary-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Mobile Notary". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my notary-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Lakeside Mobile Notary in Kirkland, Washington, Pacific time. It's just me, Dana Reyes, dana@example.com, 425-555-0100. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the notary on the phone), and calls `form_create` once (free) to build the Signing Completion Record you fill in after each signing: outcome, documents notarized, ID type (type only), scan-backs, tracking number, a photo of the drop receipt, and notes. No signature pad, no ID numbers. It stores the form id so every signing gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Optional but recommended: "Allow check-in 20 minutes early and set the radius to 150 m." Notaries arrive early and often park far from a hospital or office entrance.

Agency mode: "Add my sub Marcus Bell, marcus@example.com, I pay him $90 a signing" for each notary you dispatch.

## 6. Book your first signing

Paste the confirmation you received, then:

> Book it.

Behind the scenes the AI extracts the client, order number, type, signer, address, time, and fees; adds the client if new (asks for their payment terms); checks whether you have been to that address before, and if not calls `location_create` (geocode, $0.03, may trigger the $5 activation deposit the first time); saves the appointment as `A-2026-0001` with the signer's name and phone kept local; creates a single-day `event_create` titled `Refi signing A-2026-0001`, attaches the Completion Record with `form_assign`, and creates the `shift_create` for the signing window. You get one line back with the appointment number, the fees, and the drop deadline.

## 7. The signing

Your phone shows the signing. At the door, **Check in** (GPS-verified). Do the signing. **Check out**. Drop the package. Open the **Signing Completion Record** on the shift: outcome, documents notarized, ID type, scan-backs sent or pending, tracking number, photo of the receipt. Submit.

## 8. Close out

> Close out today. Torres: Book 3, entries 412 to 417, all acknowledgments. 23 miles round trip.

The AI pulls your GPS-verified arrival and departure (free), reads the Completion Record (metered, so it tells you the cost first, about $0.15 with the photo), updates the appointment, stores the journal pointer and the miles, and tells you what is now receivable.

> Was I on time at the Kim signing?

Answered from the local record, free: scheduled vs GPS-verified check-in, distance from the pin.

> Walsh no-showed. Get me the trip fee.

Marks the appointment a no-show (trip and no-sign fee stay billable) and drafts the note to the signing service with your GPS-verified arrival and minutes waited.

> What do I still have to drop?

Anything completed whose FedEx/UPS deadline is within 24 hours and not yet dropped.

## 9. Money

> Invoice Snapdocs.

A plain-text invoice under Snapdocs' terms with one line per appointment (your number, date, type, their order ref, fee breakdown). Nothing about signers on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Snapdocs paid INV-2026-0002.

Marks it paid.

> Mileage for September?

Trips, miles, and the deduction at the IRS rate.

Agency: "What do I owe Marcus?" lists his unpaid signings and total; "paid Marcus" marks them.

## What next

- `README.md` for the full explanation, the journal / privacy boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
