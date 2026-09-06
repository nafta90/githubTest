# JV Feeder Power App — Design Spec

Lets org members without Python skills turn their own extract file into a
populated Banner JV Feeder, using the same field mapping and transforms as
`populate_jv_feeder.py`, without needing an Azure Function or a premium
Power Platform license (same "standard connectors only" pattern as the
Implant Requisition Bridge).

## Required feeder columns (what the app asks users to map)

These are the *target* columns from the template — the ones a user maps
their own file's headers onto — not the Epic extract's internal field
names:

| Feeder column | Source transform | Configurable? |
|---|---|---|
| `RULECODE` | strip to last 3 digits | **Toggle, default OFF** — Epic-specific (chart-prefixed codes) |
| `DOCREFERENCENUMBER` | copied as-is | — |
| `AMOUNT` | divide by 100, round to 2 decimals | **Toggle, default OFF** — Epic-specific (cents-as-integer) |
| `DESCRIPTION` | copied as-is | — |
| `SIGN (+/-)` | copied as-is | — |
| `BANKCODE` | strip trailing "2" | Always applied — universal Banner format |
| `FUND` | copied as-is (blank stays blank) | — |
| `ORG` | copied as-is (blank stays blank) | — |
| `ACCOUNT` | copied as-is | — |
| `PROGRAM` | copied as-is (blank stays blank) | — |

Not shown in the mapping UI (no source column needed):

- `COA` — hardcoded to `2` for every row. Note in the app's review step:
  users on a different chart (1, 3, 9) fix this manually before uploading
  to Banner.
- `ACTIVITY`, `LOCATION`, `ENCDNUM`, `ENCDITEMNUM`, `ENCDSEQNUM`,
  `ENCDACTIONIND`, `ENCBTYPE` — always left blank.

## Architecture

Canvas App (upload + mapping UI + download) → Power Automate (orchestration)
→ Office Scripts (Excel Online, standard connector) for all file work.
No Azure Function, no custom connector, no premium license required.

```
1. Upload        Canvas App captures the file, flow saves it to a
                  SharePoint document library (working folder).

2. Read headers   Flow runs ReadSourceRows.ts against the uploaded file.
                  Returns { headers, rows } as JSON.
                  Canvas App shows `headers` as dropdown options next to
                  each required feeder column.

3. Map columns    User matches each required feeder column to one of their
                  file's headers, and sets the two toggles
                  (amountDivideBy100, ruleCodeStripPrefix) — both default
                  off.

4. Populate       Flow copies the blank JV Feeder Template (SharePoint
                  "Copy file"), then runs PopulateFeederTemplate.ts against
                  the copy, passing:
                    - sourceDataJson    (from step 2)
                    - columnMappingJson (from step 3)
                    - optionsJson       (from step 3)

5. Download       Flow returns the populated copy's file content/link to
                  the Canvas App, which surfaces a download button.
                  User reviews (incl. the COA note above) before
                  uploading to Banner.
```

## Files

- `office-scripts/ReadSourceRows.ts` — reads an uploaded file's header +
  data rows, returns JSON. Run against the **uploaded source file**.
- `office-scripts/PopulateFeederTemplate.ts` — applies the column mapping
  and transforms, writes rows into the template. Run against a **copy of
  the blank template**, never the original.

Both are meant to be pasted into Excel Online's Automate tab (or the
Office Scripts editor) and referenced by name in the Power Automate
"Run script" action — Office Scripts aren't deployed via git, so treat
these files as the source of truth to copy from.

## Open items for the Canvas App build

- Exact layout of the mapping screen (Gallery of required columns, each
  with a Dropdown bound to `headers`).
- Where "working" uploads and generated outputs get cleaned up (a
  short-retention SharePoint library, since this is financial data).
- Validation before enabling the "Generate" button: every required column
  mapped to a source header (the app should not silently proceed with
  unmapped fields — surface unmapped ones to the user).
