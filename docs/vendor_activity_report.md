# Vendor Activity Report — Data Dictionary & Usage

### Purpose

- **Report:** vendor activity for the College of Dentistry (college code `FN` by default), time-period agnostic with an optional date-range filter.
- **Covers:** invoices with line-item detail, payments (checks/ACH), purchase order information, FOAP codes (Fund, Org, Account, Program + Activity/Location) with titles, PO requestor/buyer info, and vendor master attributes.
- **Source:** Finance EDW (Banner Decision Support physical model, `FIN_EDW_Physical_Model_Report`).
- **Query file:** [`sql/vendor_activity_report.sql`](../sql/vendor_activity_report.sql) (Oracle).

---

### Report grain — read this before summing

- **One row = one invoice line item × one FOAP accounting distribution** (`T_INV_VCHR_ACCTG_DETL`).
- **Safe to SUM:** the `ACCTG_DETL_*` amount columns and the `PAID_*` payment columns — both live at the report grain.
- **NOT safe to SUM naively:** `LINE_ITEM_*` amounts repeat when a line item is split across multiple FOAP distributions. Sum them only after de-duplicating by invoice doc + line item number.
- **Payments are pre-aggregated** (a distribution paid by several checks still yields one row); check numbers are concatenated in `CHK_NBR_LIST`.

---

### Parameters

- **Where:** edit the `params` CTE at the very top of the SQL file — there are **no bind variables**, so the query runs unchanged through **ODBC / Power Query / Excel / Power BI** (bind variables cause `ORA-01008: not all variables bound` in those tools).

| Field in `params` | Type | Behavior |
|---|---|---|
| `start_dt` | DATE | Invoices on/after this date (`INV_VCHR_DT`). `NULL` = no lower bound. Example: `DATE '2024-07-01'`. |
| `end_dt` | DATE | Invoices on/before this date (inclusive of the full day). `NULL` = no upper bound. |
| `coll_cd` | VARCHAR2 | College code from the Org hierarchy (`COLL_LEVEL_3_CD`). **Default `'FN'` (Dentistry).** |
| `vend_id` | VARCHAR2 | Optional single vendor (`T_VEND.VEND_ID`). `NULL` = all vendors. |

- **All date/vendor fields NULL** → entire history for college `FN`, every vendor.
- In Power Query you can also wire these to workbook/report parameters by splicing the values into the query text (e.g. `"... CAST(" & StartDateText & " AS DATE) AS start_dt ..."`).
- Fiscal **`FY_CD` / `FISC_PERD_CD`** are included as output columns, so a reporting tool can also slice by fiscal period without changing the SQL.

---

### Source tables & joins

| Table | Role | Join |
|---|---|---|
| `T_INV_VCHR` | Invoice voucher header (driver) | — |
| `T_INV_VCHR_LINE_ITEM` | Invoice line items | `EDW_FIN_DOC_ID` |
| `T_INV_VCHR_ACCTG_DETL` | FOAP distributions (grain) | `EDW_FIN_DOC_ID` + `INV_VCHR_LINE_ITEM_NBR` |
| `T_VEND` | Vendor master | `INV_VCHR_VEND_EDW_PARTY_ID` → `EDW_PARTY_ID` |
| `T_PO` | PO header | LEFT on `PO_EDW_FIN_DOC_ID` |
| `T_PO_LINE_ITEM` | Matched PO line | LEFT on line item's `PO_EDW_FIN_DOC_ID` + `PO_LINE_ITEM_NBR` |
| `T_BANK_CHK_INV_VCHR_DETL` | Check ↔ invoice link | aggregated CTE at doc/line/seq grain |
| `T_BANK_CHK` | Check header (date, amount, ACH, cancel) | `(EDW_FIN_DOC_ID, BANK_CHK_BANK_CD)` |
| `T_POST_DOC` | Human-readable doc numbers | once each for invoice, PO, and check `EDW_FIN_DOC_ID` |
| `T_ORG_CD_HIST` | Org titles + college/dept rollup | `(COA_CD, ORG_CD)`, current row (`ORG_CD_CUR_INFO_IND='Y'`) |
| `T_FIN_FUND_CD_HIST` | Fund title | `(COA_CD, FIN_FUND_CD)`, current row |
| `T_FIN_ACCT_CD_HIST` | Account title | `(COA_CD, FIN_ACCT_CD)`, current row |
| `T_FIN_PGM_CD_HIST` | Program title | `(COA_CD, FIN_PGM_CD)`, current row |

**College filter mechanics:** the Org hierarchy table `T_ORG_CD_HIST` carries the rollup levels (Campus L1 → Admin L2 → **College L3** → School L4 → Dept L5…). The report keeps the *current* hierarchy row per org and filters `COLL_LEVEL_3_CD = NVL(:p_coll_cd,'FN')`. Historical reorgs therefore classify under today's hierarchy; if you need "college as of the transaction date," join `T_ORG_CD_HIST` on the effective-date range instead of `CUR_INFO_IND`.

---

### Column groups (output)

- **Vendor:** `VEND_ID`, `VEND_NAME`, income type (1099), in-state flag, business state/nation, contact person/phone, one-time-vendor flag, invoice-time vendor city/state.
- **Invoice:** EDW doc number (`INV_DOC_NBR`), vendor's own invoice number (`VEND_INV_NBR`), invoice/transaction/payment-due dates, type, credit-memo / 1099 / hold / cancel / open-period indicators, create source.
- **Line item:** number, commodity code + description, UOM, invoiced qty & price, received / accepted / approved qty, tax / discount / additional / net amounts, receiving status.
- **FOAP distribution:** COA, fiscal year & period, **Fund + title, Org + title, college code & title, department code & title, Account + title, Program + title**, Activity, Location, paid indicator, and the distribution-level amounts (invoice, approved, tax, discount, additional, net).
- **Purchase order:** PO number, order & delivery dates, type/class, **requestor name & email (`PO_RQSTR_NAME`, `PO_RQSTR_EMAIL_ADDR`), buyer code & name (`PO_BYR_CD`, `PO_BYR_NAME`)**, attention name, PO org, cancel/receiving flags, blanket-order reference, matched PO line (qty, unit price, net amount, vendor ref).
- **Payments:** check count, concatenated check numbers (ACH / cancelled annotated inline), first & last check dates, paid gross/discount/additional amounts, federal & state withholding, any-ACH and any-cancelled flags, derived `PAYMENT_STATUS` (`PAID` / `UNPAID`).

---

### Known model gaps & conventions

- **PO "creator":** the EDW model does not store a creator user-ID. The closest fields are the **requestor** (`PO_RQSTR_NAME`, `PO_RQSTR_EMAIL_ADDR`) and the assigned **buyer** (`PO_BYR_CD`, `PO_BYR_NAME`), both included. If you need the Banner user who keyed the PO, that would require a source-system (e.g. `FPBPOHD.FPBPOHD_USER_ID`) extract not present in this model.
- **Document numbers:** `EDW_FIN_DOC_ID` is a warehouse surrogate; the Banner document numbers you recognize (I-docs, P-docs, check numbers) come from `T_POST_DOC.POST_DOC_NBR`.
- **Cancellations included:** cancelled invoices and checks appear with flags (`INV_CNCL_IND`, `PAID_ANY_CHK_CNCL_IND`) rather than being filtered out, so cancelled activity stays auditable. Add `AND iv.INV_VCHR_CNCL_IND = 'N'` to exclude.
- **Non-PO invoices:** direct-pay invoices (no PO) still appear; their PO columns are simply NULL (LEFT joins).
- **`LISTAGG` length:** an invoice distribution paid by very many checks could overflow `LISTAGG`'s 4000-byte limit; on Oracle 12.2+ you may add `ON OVERFLOW TRUNCATE` inside the `LISTAGG` call.

---

### Verification checklist

1. Run with all binds NULL — should return all-history activity for college `FN` only (spot-check `COLLEGE_CD` = 'FN' on every row).
2. Pick one invoice with a split FOAP: confirm the sum of its `ACCTG_DETL_NET_AMT` rows equals the invoice line's `LINE_ITEM_NET_AMT`.
3. Pick one paid invoice: confirm `PAID_GROSS_AMT` totals match the check amounts in Banner (`T_BANK_CHK.BANK_CHK_AMT` may cover multiple invoices per check — compare at the detail level, not the check header).
4. Set `:p_start_dt` / `:p_end_dt` to one month and confirm row counts shrink accordingly.
