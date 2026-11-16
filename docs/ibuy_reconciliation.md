# iBuy ↔ EDW Invoice Reconciliation Recipe

### Purpose

Join the Jaggaer/iBuy invoice export (buyer invoice search, "transaction export" with line details) to the EDW detail report (`sql/vendor_activity_report.sql`) so every Banner invoice line carries the real iBuy product descriptions — including one-line standing orders.

### The iBuy export to use

- **Search:** Documents → Search → Invoices → filter supplier/date → Export All → transaction export with line details.
- **Verified fields (all populated):** `Supplier Invoice No`, `PO No`, `PO Line No`, `Catalog No`, `Product Name`, `Invoice Line Unit Price`, `Quantity`, `UOM`, `Invoice Line Extended Price`, `Invoice Total`, `Invoice Status`, `Workflow Status`, `Paid Date`, plus Banner FOAP columns (`Fund-Banner`, `Organization - Banner`, `Account - Banner`, `Program - Banner`).
- **Encoding:** the file is Windows-1252, not UTF-8 — in Power Query set the CSV origin to `1252 (Western European)` if accents look wrong.

### Join keys

| iBuy column | EDW report column | Notes |
|---|---|---|
| `Supplier Invoice No` | `VEND_INV_NBR` | **Primary key.** Normalize both: trim + UPPERCASE. Banner may truncate long numbers — fall back to PO + date + amount if a few don't match. |
| `PO No` | `PO_NBR` | Secondary/validation key (iBuy `P3103038` = Banner P-number, same format). |
| `PO Line No` | `PO_LINE_ITEM_NBR` | Works for regular POs. **Not for standing orders** — there, many iBuy lines map to Banner's single line, so join those at invoice level only. |
| `Supplier Number` (strip the leading `@`) | `VEND_ID` | Tie-breaker across vendors. |

### Power Query steps (Excel / Power BI)

1. **Query 1 — EDW:** ODBC → Oracle → paste `vendor_activity_report.sql`. Add a custom column `INV_KEY = Text.Upper(Text.Trim([VEND_INV_NBR]))`.
2. **Query 2 — iBuy:** load the CSV (file origin 1252). Add `INV_KEY = Text.Upper(Text.Trim([Supplier Invoice No]))`.
3. **Line-level merge (regular POs):** Merge Query 1 ← Query 2 on `INV_KEY` **and** `PO_LINE_ITEM_NBR` = `PO Line No` (Left Outer). Expand `Product Name`, `Catalog No`, `Invoice Line Extended Price`.
4. **Invoice-level merge (standing orders / unmatched lines):** group Query 2 by `INV_KEY` with `All Products = Text.Combine([Product Name], "; ")` and `iBuy Line Total = List.Sum([Invoice Line Extended Price])`, then merge that on `INV_KEY` alone to fill rows the line-level merge left empty.
5. **Tie-out column:** `[ACCTG_DETL_NET_AMT] - [Invoice Line Extended Price]` (or vs. the grouped total for standing orders); filter to `<> 0` to see mismatches.

### Findings from profiling the first export (Henry Schein, 2026)

- **863 rows, 234 invoices, 62 POs; keys 100% populated; `Quantity × Unit Price = Extended Price` holds on every line.** The export is reliable for line-level matching.
- **15 of 234 invoices have `Invoice Total` ≠ sum of line extended prices** — header-level charges (tax/shipping/handling columns in the export). This is a likely cause of "line price doesn't match the invoice copy" comparisons: compare *line* amounts to `LINE_ITEM_NET_AMT`/`ACCTG_DETL_NET_AMT` and reconcile header charges separately.
- **One duplicate line key** (`IV093956`, PO line 1 appears twice) — a quantity split; sum duplicates before a line-level merge or they will fan out.
- **4 cancelled and 43 in-process invoices** are in the export — filter `Invoice Status` when comparing against the EDW, which only has posted documents.
- **Scope:** this export is one supplier and ~1 year. For the full reconciliation, re-run the iBuy search with the same ~2-year window and supplier set as the EDW report.
