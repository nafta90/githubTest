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