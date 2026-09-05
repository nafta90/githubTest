# githubTest

## Epic GL extract script

`scripts/epic_gl_extract.py` converts the two fixed-width text files Epic
exports each period into a single `.xlsx` workbook (one sheet per source
file) for building the Banner journal feeder:

- `fi_gl_transactions<Month>.txt` -> `acct-level extract` sheet
- `detailCODGL<Month>.txt` -> `detail extract` sheet

### Usage

```bash
python3 scripts/epic_gl_extract.py \
  --gl fi_gl_transactionsJul.txt \
  --detail detailCODGLJul.txt \
  --output July_GL_extract.xlsx
```

Requires `openpyxl` (`pip install openpyxl`).

`--gl` and `--detail` are both optional, but at least one is required — pass
just the one you have and the output workbook will contain only that sheet:

```bash
python3 scripts/epic_gl_extract.py --gl fi_gl_transactionsJul.txt --output July_acct_level.xlsx
python3 scripts/epic_gl_extract.py --detail detailCODGLJul.txt --output July_detail.xlsx
```

The script cross-checks the parsed `acct-level extract` row count and total
amount against the trailer control record embedded in the `fi_gl_transactions`
file, and prints a warning if they don't match — that's the signal to check
whether Epic changed the export's column layout.

## JV feeder population script

`scripts/populate_jv_feeder.py` takes the `acct-level extract` sheet from an
extract workbook (output of `epic_gl_extract.py`) and maps it into a copy of
the Banner `JV Feeder Template.xlsx`, ready to post.

### Usage

```bash
python3 scripts/populate_jv_feeder.py \
  --extract July_GL_extract.xlsx \
  --template templates/JVFeederTemplate.xlsx \
  --output July_JV_Feeder.xlsx
```

### Field mapping

| Extract column | Feeder column | Transform |
|---|---|---|
| `rule` | `RULECODE` | strip the leading `2` — keep the last 3 digits (2125 -> 125) |
| `date` | `DOCREFERENCENUMBER` | copied as-is |
| `amt` | `AMOUNT` | cents -> dollars (`amt / 100`) |
| `type` | `DESCRIPTION` | copied as-is |
| `dbOrCr` | `SIGN (+/-)` | copied as-is |
| `bank` | `BANKCODE` | strip the trailing `2` (that digit is the COA, not part of the bank code) — `"LJ2"` -> `"LJ"`, plain `2` -> blank |
| — | `COA` | always `2` (hardcoded) |
| `fund` | `FUND` | copied as-is (blank stays blank) |
| `org` | `ORG` | copied as-is (blank stays blank) |
| `acct` | `ACCOUNT` | copied as-is |
| `prog` | `PROGRAM` | copied as-is (blank stays blank) |

`ACTIVITY`, `LOCATION`, `ENCDNUM`, `ENCDITEMNUM`, `ENCDSEQNUM`,
`ENCDACTIONIND`, and `ENCBTYPE` are left blank on every row — they're unused
for this feed.

## Full automation: watch a folder and run both scripts

`scripts/watch_and_process.py` ties the two scripts above into one pipeline.
Point it at an inbox folder; each time it runs, it:

1. Looks for a matching pair of `fi_gl_transactions<Period>.txt` /
   `detailCODGL<Period>.txt` files (paired by whatever follows the fixed
   prefix in the filename, e.g. `Jul`).
2. Waits until a found file's size is stable (so a file still mid-copy onto
   a network/cloud drive isn't read half-written) — if it's still changing,
   that period is skipped and picked up on the next run.
3. Runs `epic_gl_extract.py`'s logic to write `<Period>_GL_extract.xlsx`,
   then `populate_jv_feeder.py`'s logic to write `<Period>_JV_Feeder.xlsx`,
   both into the output folder.
4. Moves the two source `.txt` files into a timestamped `processed`
   subfolder of the inbox, so they're never picked up and reprocessed.
5. Appends everything it did (or "nothing to do") to a log file, so a
   scheduled run's history is auditable.

It's designed to be run periodically rather than kept running continuously
— each run scans once and exits; running it again when nothing new has
arrived is a fast no-op.

### Usage

```bash
python3 scripts/watch_and_process.py \
  --inbox "I:\Fiscal Affairs\FINANCE- Alex A\Epic\GL Test" \
  --output "I:\Fiscal Affairs\FINANCE- Alex A\Epic\GL Output" \
  --template templates\JVFeederTemplate.xlsx
```

(Adjust the paths for wherever Epic actually drops the files and wherever
you want the extract/feeder workbooks to land — network share, OneDrive
sync folder, or a local folder all work the same way, since the script
just reads/writes files at the paths you give it.)

### Scheduling it on Windows (Task Scheduler)

1. Open **Task Scheduler** → **Create Task...** (not "Basic Task", so you
   get the "run whether user is logged on or not" option).
2. **General** tab: give it a name (e.g. "Epic GL Feeder"), and check "Run
   whether user is logged on or not" if you want it to work even when
   you're not logged in.
3. **Triggers** tab → **New...** → "Daily", recurring every 1 day, and
   check "Repeat task every: 15 minutes" for "a duration of: Indefinitely"
   — this polls every 15 minutes instead of running once a day.
4. **Actions** tab → **New...**:
   - Program/script: `uv`
   - Add arguments:
     ```
     run --with openpyxl scripts\watch_and_process.py --inbox "I:\Fiscal Affairs\FINANCE- Alex A\Epic\GL Test" --output "I:\Fiscal Affairs\FINANCE- Alex A\Epic\GL Output" --template templates\JVFeederTemplate.xlsx
     ```
   - Start in: the folder containing this repo (e.g.
     `C:\Users\adamov.000\Documents\Python Scripts\work\epic`)
5. Save, then right-click the task → **Run** once to confirm it works, and
   check the log file in the output folder.

Once you know the actual inbox folder, that's the only thing to fill in —
everything else in this setup stays the same.