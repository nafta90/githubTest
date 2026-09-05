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