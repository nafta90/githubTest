-- ============================================================================
-- axiUm "A/R Reconciliation Report (Summary) - All Departments (no criteria)"
-- Recreated for Excel / ODBC (DSN "axiUm DB", Oracle, user fin_powerbi_readonly)
--
-- The report period defaults to the PREVIOUS FULL CALENDAR MONTH
-- (run it any time during September and you get August, etc.).
-- To pin a specific month instead, replace the two date expressions:
--     TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')  -->  DATE '2026-08-01'
--     TRUNC(SYSDATE, 'MM')                  -->  DATE '2026-09-01'
--
-- Conventions used throughout (from the data dictionary):
--   * Column names are mixed case and MUST be double-quoted.
--   * TRX."Type": 1=Treatment, 2=Office charge, 3=Patient payment,
--     4=Insurance payment, 6=Adjustment, 7=Insurance adjustment.
--     Types 73/74 are allocated portions of payments - always excluded.
--   * NVL("Deleted",0)=0 keeps only active rows.
--   * Payments/credit adjustments are stored negative, so every section
--     and the A/R balances are plain SUMs of TRX."Total".
--   * Provider Group = PRODUCER."PGroup" via TRX."Producer".
--
-- EXCEL PASTING RULE (avoids ODBC error ORA-24374):
--   Copy ONLY the bare statement, from the word SELECT down to the last
--   line of the query. Do NOT include any of these comment lines, and the
--   statement must NOT end with a semicolon.
-- ============================================================================


-- ============================================================================
-- QUERY 1: Report body - section totals by Provider Group
-- (Treatments / Patient Payments / Patient Adjustments /
--  Insurance Payments / Insurance Adjustments)
--
-- HOW GROUPING WORKS (matches the real report):
--   * Treatments/office charges are grouped by the provider group of the
--     transaction's own producer.
--   * Payments and adjustments carry NO producer of their own. The report
--     attributes them to the provider group of the CHARGE each payment was
--     allocated to (via ALLOCATE). Any portion not yet allocated shows
--     under 'No Provider Group'.
--
-- SIGNS (confirmed against the Aug 2026 printout): ALLOCATE."Amount" is
--   stored POSITIVE for payments (types 3/4) but ALREADY NEGATIVE for
--   adjustments (types 6/7), hence the CASE expressions in branches 2 and 3.
--
-- VALIDATION: pin the dates to August 2026 (replace every
--   TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM') with DATE '2026-08-01' and every
--   TRUNC(SYSDATE, 'MM') with DATE '2026-09-01') and compare to the PDF:
--   Treatments 3,606,892.47 / Pt Pmts -655,400.89 / Pt Adj -200,152.32 /
--   Ins Pmts -2,029,388.79 / Ins Adj -1,810,128.16.
--   Note: allocations reflect TODAY's state, so months closed long ago can
--   drift slightly between groups (section totals stay exact).
-- ============================================================================
SELECT
    "Section",
    "SectionOrder",
    "Provider Group",
    SUM("Amt") AS "Amount"
FROM (
    SELECT
        CASE t."Type" WHEN 1 THEN 'Treatments'
                      ELSE 'Office Charges' END     AS "Section",
        CASE t."Type" WHEN 1 THEN 1 ELSE 2 END      AS "SectionOrder",
        NVL(TRIM(p."PGroup"), 'No Provider Group')  AS "Provider Group",
        t."Total"                                   AS "Amt"
    FROM axium.trx t
    LEFT JOIN axium.producer p
           ON p."Producer" = t."Producer"
    WHERE t."Type" IN (1, 2)
      AND NVL(t."Deleted", 0) = 0
      AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
      AND t."Date" <  TRUNC(SYSDATE, 'MM')
    UNION ALL
    SELECT
        CASE pay."Type" WHEN 3 THEN 'Patient Payments'
                        WHEN 6 THEN 'Patient Adjustments'
                        WHEN 4 THEN 'Insurance Payments'
                        ELSE 'Insurance Adjustments' END,
        CASE pay."Type" WHEN 3 THEN 3 WHEN 6 THEN 4
                        WHEN 4 THEN 5 ELSE 6 END,
        NVL(TRIM(p."PGroup"), 'No Provider Group'),
        CASE WHEN pay."Type" IN (3, 4) THEN - a."Amount"
             ELSE a."Amount" END
    FROM axium.trx pay
    JOIN axium.allocate a
      ON  a."PayType"      = pay."Type"
      AND a."PayId"        = pay."Id"
      AND a."PayTreatment" = pay."Treatment"
    LEFT JOIN axium.trx chg
      ON  chg."Type"      = a."TrxType"
      AND chg."Id"        = a."TrxId"
      AND chg."Treatment" = a."TrxTreatment"
    LEFT JOIN axium.producer p
           ON p."Producer" = chg."Producer"
    WHERE pay."Type" IN (3, 4, 6, 7)
      AND NVL(pay."Deleted", 0) = 0
      AND pay."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
      AND pay."Date" <  TRUNC(SYSDATE, 'MM')
    UNION ALL
    SELECT
        CASE pay."Type" WHEN 3 THEN 'Patient Payments'
                        WHEN 6 THEN 'Patient Adjustments'
                        WHEN 4 THEN 'Insurance Payments'
                        ELSE 'Insurance Adjustments' END,
        CASE pay."Type" WHEN 3 THEN 3 WHEN 6 THEN 4
                        WHEN 4 THEN 5 ELSE 6 END,
        'No Provider Group',
        pay."Total" + CASE WHEN pay."Type" IN (3, 4) THEN NVL(al."Allocated", 0)
                           ELSE - NVL(al."Allocated", 0) END
    FROM axium.trx pay
    LEFT JOIN (
        SELECT "PayType", "PayId", "PayTreatment",
               SUM("Amount") AS "Allocated"
        FROM axium.allocate
        GROUP BY "PayType", "PayId", "PayTreatment"
    ) al
      ON  al."PayType"      = pay."Type"
      AND al."PayId"        = pay."Id"
      AND al."PayTreatment" = pay."Treatment"
    WHERE pay."Type" IN (3, 4, 6, 7)
      AND NVL(pay."Deleted", 0) = 0
      AND pay."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
      AND pay."Date" <  TRUNC(SYSDATE, 'MM')
) x
GROUP BY "Section", "SectionOrder", "Provider Group"
HAVING ABS(SUM("Amt")) > 0.005
ORDER BY "SectionOrder", "Provider Group"


-- ============================================================================
-- QUERY 2: Opening and closing A/R balances
-- ("A/R as at <start>" and "A/R as at <end>")
-- A/R at any point = cumulative sum of all charge/payment/adjustment totals.
-- ============================================================================
SELECT
    SUM(CASE WHEN t."Date" < TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
             THEN t."Total" END)  AS "AR Opening",
    SUM(t."Total")                AS "AR Closing"
FROM axium.trx t
WHERE t."Type" IN (1, 2, 3, 4, 6, 7)
  AND NVL(t."Deleted", 0) = 0
  AND t."Date" < TRUNC(SYSDATE, 'MM')


-- ============================================================================
-- QUERY 3: Unallocated Receivables summary (bottom of the report)
-- Held amount = payment total plus everything allocated from it.
-- NOTE: ALLOCATE reflects allocations as of TODAY, not as of month end,
-- so run this soon after month end for a faithful as-at figure.
-- ============================================================================
SELECT
    CASE t."Type"
        WHEN 3 THEN 'Patient Payments'
        WHEN 6 THEN 'Patient Adjustment'
        WHEN 4 THEN 'Insurance Payments'
        WHEN 7 THEN 'Insurance Adjustment'
    END                           AS "Section",
    SUM(t."Total" + NVL(a."Allocated", 0)) AS "Unallocated"
FROM axium.trx t
LEFT JOIN (
    SELECT "PayType", "PayId", "PayTreatment",
           SUM("Amount") AS "Allocated"
    FROM axium.allocate
    GROUP BY "PayType", "PayId", "PayTreatment"
) a
  ON  a."PayType"      = t."Type"
  AND a."PayId"        = t."Id"
  AND a."PayTreatment" = t."Treatment"
WHERE t."Type" IN (3, 4, 6, 7)
  AND NVL(t."Deleted", 0) = 0
  AND t."Date" < TRUNC(SYSDATE, 'MM')
GROUP BY
    CASE t."Type"
        WHEN 3 THEN 'Patient Payments'
        WHEN 6 THEN 'Patient Adjustment'
        WHEN 4 THEN 'Insurance Payments'
        WHEN 7 THEN 'Insurance Adjustment'
    END
HAVING ABS(SUM(t."Total" + NVL(a."Allocated", 0))) > 0.005
ORDER BY 1


-- ============================================================================
-- QUERY 4: "(not fully allocated)" detail lines
-- One row per payment/adjustment still carrying a held (unallocated) amount.
-- Mirrors the report's detail columns:
--   Date | Tx Date | Description | Code | Patient | Payment Total | Held Amount
-- For Type 3/6 the patient being paid for is TRX."Family" (TRX."Patient" is
-- the payor); for Type 4/7 it is TRX."Patient".
-- CONTAINS PHI - keep the output inside your normal reporting controls.
-- ============================================================================
SELECT
    CASE t."Type"
        WHEN 3 THEN 'Patient Payments'
        WHEN 6 THEN 'Patient Adjustment'
        WHEN 4 THEN 'Insurance Payments'
        WHEN 7 THEN 'Insurance Adjustment'
    END                                  AS "Section",
    t."CreationDate"                     AS "Date",
    t."Date"                             AS "Tx Date",
    t."Description"                      AS "Description",
    TRIM(t."Code")                       AS "Code",
    TRIM(pt."Last") || ', ' || TRIM(pt."First") AS "Patient",
    t."Total"                            AS "Payment Total",
    t."Total" + NVL(a."Allocated", 0)    AS "Held Amount"
FROM axium.trx t
LEFT JOIN (
    SELECT "PayType", "PayId", "PayTreatment",
           SUM("Amount") AS "Allocated"
    FROM axium.allocate
    GROUP BY "PayType", "PayId", "PayTreatment"
) a
  ON  a."PayType"      = t."Type"
  AND a."PayId"        = t."Id"
  AND a."PayTreatment" = t."Treatment"
LEFT JOIN axium.patient pt
  ON pt."Patient" = CASE WHEN t."Type" IN (3, 6) THEN t."Family"
                         ELSE t."Patient" END
WHERE t."Type" IN (3, 4, 6, 7)
  AND NVL(t."Deleted", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
  AND ABS(t."Total" + NVL(a."Allocated", 0)) > 0.005
ORDER BY "Section", t."Date", t."Id"


-- ============================================================================
-- QUERY 5: ONE-TIME VALIDATION DIAGNOSTIC for August 2026
-- The PDF was printed Sep 1, 2026; the live database has kept changing
-- August-dated rows since (late entries backdated into August, and
-- deletions/corrections made after Sep 1). This query shows, per
-- transaction type and treatment status:
--   "Current Total"   = what the live data says today
--   "AsAt Sep1 Total"  = only rows created before Sep 1 and not deleted
--                        before Sep 1 (reconstruction of the print-time view)
-- Compare "AsAt Sep1 Total" per type to the PDF section totals:
--   Type 1 -> 3,606,892.47   Type 3 -> -655,400.89   Type 6 -> -200,152.32
--   Type 4 -> -2,029,388.79  Type 7 -> -1,810,128.16
-- ============================================================================
SELECT
    t."Type",
    TRIM(t."Status")  AS "Status",
    COUNT(*)          AS "Rows",
    SUM(CASE WHEN NVL(t."Deleted", 0) = 0
             THEN t."Total" END) AS "Current Total",
    SUM(CASE WHEN t."CreationDate" < DATE '2026-09-01'
              AND (NVL(t."Deleted", 0) = 0
                   OR t."DeletionDate" >= DATE '2026-09-01')
             THEN t."Total" END) AS "AsAt Sep1 Total"
FROM axium.trx t
WHERE t."Type" IN (1, 2, 3, 4, 6, 7)
  AND t."Date" >= DATE '2026-08-01'
  AND t."Date" <  DATE '2026-09-01'
GROUP BY t."Type", TRIM(t."Status")
ORDER BY t."Type", TRIM(t."Status")


-- ============================================================================
-- QUERY 6: DIAGNOSTIC - section totals by TX DATE vs ENTRY DATE (Aug 2026)
-- Type 6 proved the report cannot be selecting by transaction date
-- (current = as-at-Sep-1, yet both differ from the PDF). This tests the
-- entry-date (CreationDate) hypothesis. Compare each type's "By Entry Date"
-- to the PDF: 1 -> 3,606,892.47 / 3 -> -655,400.89 / 6 -> -200,152.32 /
-- 4 -> -2,029,388.79 / 7 -> -1,810,128.16
-- ============================================================================
SELECT
    t."Type",
    TRIM(t."Status") AS "Status",
    SUM(CASE WHEN t."Date" >= DATE '2026-08-01'
              AND t."Date" <  DATE '2026-09-01'
             THEN t."Total" END) AS "By Tx Date",
    SUM(CASE WHEN t."CreationDate" >= DATE '2026-08-01'
              AND t."CreationDate" <  DATE '2026-09-01'
             THEN t."Total" END) AS "By Entry Date"
FROM axium.trx t
WHERE t."Type" IN (1, 2, 3, 4, 6, 7)
  AND NVL(t."Deleted", 0) = 0
  AND (   (t."Date" >= DATE '2026-08-01' AND t."Date" < DATE '2026-09-01')
       OR (t."CreationDate" >= DATE '2026-08-01' AND t."CreationDate" < DATE '2026-09-01'))
GROUP BY t."Type", TRIM(t."Status")
ORDER BY t."Type", TRIM(t."Status")


-- ============================================================================
-- QUERY 7: DIAGNOSTIC - A/R balances by TX DATE vs ENTRY DATE
-- The decisive test. PDF targets:
--   A/R as at Aug 01: 20,816,258.52     A/R as at Aug 31: 19,728,080.83
-- Whichever date basis reproduces BOTH balances is the one the report uses.
-- (Scans the whole TRX table - expect it to take a minute or two.)
-- ============================================================================
SELECT
    SUM(CASE WHEN t."Date" < DATE '2026-08-01'
             THEN t."Total" END) AS "Open by TxDate",
    SUM(CASE WHEN t."Date" < DATE '2026-09-01'
             THEN t."Total" END) AS "Close by TxDate",
    SUM(CASE WHEN t."CreationDate" < DATE '2026-08-01'
             THEN t."Total" END) AS "Open by EntryDate",
    SUM(CASE WHEN t."CreationDate" < DATE '2026-09-01'
             THEN t."Total" END) AS "Close by EntryDate"
FROM axium.trx t
WHERE t."Type" IN (1, 2, 3, 4, 6, 7)
  AND NVL(t."Deleted", 0) = 0


-- ============================================================================
-- QUERY 8: DIAGNOSTIC - suspended / deleted / strikeout breakdown (Aug 2026)
-- Tests two remaining explanations for the per-section gaps vs the PDF:
--   * "Suspended Total": transactions pending approval. If the report
--     excludes them, these amounts explain why we OVER-count:
--     expect roughly Type 1 -> +101,715 / Type 3 -> -28,350 / Type 7 -> -24,272
--   * "Deleted"/"Strikeout" Totals: rows removed since the Sep 1 printout.
--     These explain why we UNDER-count:
--     expect roughly Type 4 -> -272,049 / Type 6 -> -38,642 among them
-- ============================================================================
SELECT
    t."Type",
    SUM(CASE WHEN NVL(t."Deleted", 0) = 0
              AND NVL(t."Suspended", 0) = 1
             THEN t."Total" END) AS "Suspended Total",
    SUM(CASE WHEN NVL(t."Deleted", 0) = 1
             THEN t."Total" END) AS "Deleted Total",
    SUM(CASE WHEN NVL(t."Deleted", 0) = 2
             THEN t."Total" END) AS "Strikeout Total",
    COUNT(CASE WHEN NVL(t."Deleted", 0) = 1
                AND t."DeletionDate" IS NULL
               THEN 1 END)       AS "Deleted no date"
FROM axium.trx t
WHERE t."Type" IN (1, 2, 3, 4, 6, 7)
  AND t."Date" >= DATE '2026-08-01'
  AND t."Date" <  DATE '2026-09-01'
GROUP BY t."Type"
ORDER BY t."Type"


-- ============================================================================
-- ======================  FINDINGS FROM THE .RPT FILE  =======================
-- The Crystal report was decrypted and parsed. The "All No Criteria" report
-- DOES NOT query TRX at all. When the report is run inside axiUm, the client
-- first computes the whole reconciliation (from axiUm's transaction HISTORY,
-- including modifications/deletions/transfers) and saves it as a numbered
-- BATCH into two tables:
--     AR_RECON_SAVED_DATA_HDR  (one row per run: Batch, FromDate, ToDate,
--                               BeginningBalance, EndingBalance, GroupBy1/2,
--                               IsDetailed, IncludeUnallocated)
--     AR_RECON_SAVED_DATA_DTL  (the lines: Batch, Type, History,
--                               ReportHistoryTypeDescription, ReportPGroup,
--                               ReportProducer, ReportTotalChange, ...)
-- Crystal merely formats one batch ({HDR.Batch} = {?Batch}). The printed
-- "A/R as at" lines are HDR.BeginningBalance / HDR.EndingBalance, and the
-- report itself checks: Beginning + Treatments - PtPmts + PtAdj - InsPmts
-- - InsAdj = Ending. This is why no live TRX query can match an old printout
-- penny-for-penny: the batch is a frozen snapshot, built from history tables
-- (TRXHIST) that the fin_powerbi_readonly account has not been granted.
--
-- TO RECREATE EXACTLY: ask the axiUm DBA to grant SELECT on
-- AR_RECON_SAVED_DATA_HDR and AR_RECON_SAVED_DATA_DTL to fin_powerbi_readonly,
-- keep running the report monthly inside axiUm (that is what creates the
-- batch), then use Queries 9-11 below to pull the identical numbers into
-- Excel. Queries 1-4 above remain the best TRX-only approximation if the
-- grant is not possible.
-- ============================================================================


-- ============================================================================
-- QUERY 9: List saved reconciliation batches (newest first)
-- Pick the Batch for the month you want; FromDate/ToDate identify the period.
-- ============================================================================
SELECT
    h."Batch",
    h."FromDate",
    h."ToDate",
    h."BeginningBalance",
    h."EndingBalance",
    h."GroupBy1",
    h."GroupBy2",
    h."IsDetailed",
    h."IncludeUnallocated"
FROM axium.ar_recon_saved_data_hdr h
ORDER BY h."Batch" DESC


-- ============================================================================
-- QUERY 10: Section totals by Provider Group for one batch (THE REPORT BODY)
-- Replace 12345 with the Batch number from Query 9.
-- Signs follow the stored convention; the printed report shows payments
-- negated, matching what you see here or its mirror - compare once and keep.
-- ============================================================================
SELECT
    d."Type",
    NVL(TRIM(d."ReportPGroup"), 'No Provider Group') AS "Provider Group",
    SUM(d."ReportTotalChange")                       AS "Amount"
FROM axium.ar_recon_saved_data_dtl d
WHERE d."Batch" = 12345
  AND d."ReportHistoryTypeDescription" NOT IN
      ('Unallocated Adjustments', 'Unallocated Insurance Payments', 'Unallocated Payments')
GROUP BY d."Type", NVL(TRIM(d."ReportPGroup"), 'No Provider Group')
ORDER BY d."Type", "Provider Group"


-- ============================================================================
-- QUERY 11: Unallocated Receivables lines for one batch
-- Replace 12345 with the Batch number from Query 9.
-- ============================================================================
SELECT
    d."ReportHistoryTypeDescription" AS "Section",
    SUM(d."ReportTotalChange")       AS "Amount"
FROM axium.ar_recon_saved_data_dtl d
WHERE d."Batch" = 12345
  AND d."ReportHistoryTypeDescription" IN
      ('Unallocated Adjustments', 'Unallocated Insurance Payments', 'Unallocated Payments')
GROUP BY d."ReportHistoryTypeDescription"
ORDER BY 1


-- ============================================================================
-- QUERY 12: PRODUCTION MONTHLY REPORT BODY (auto-batch)
-- VALIDATED penny-exact against the Aug 2026 printout (batch 10377).
-- Auto-selects the newest summary batch grouped by Provider Group (GroupBy1=2)
-- covering the previous calendar month. Workflow: run the A/R Reconciliation
-- report inside axiUm first (that creates the batch), then refresh Excel.
-- Sections combine Type 1 + 2 as 'Treatments', exactly as the report prints.
-- Signs: types 3/4/7 are negated for display parity with the printout
-- (Crystal does the same at print time). Verify Patient Adjustments (-200,152.32
-- for Aug) on first run; if it shows flipped, move Type 6 into the negated list.
-- ============================================================================
SELECT
    CASE d."Type" WHEN 1 THEN 'Treatments'
                  WHEN 2 THEN 'Treatments'
                  WHEN 3 THEN 'Patient Payments'
                  WHEN 6 THEN 'Patient Adjustments'
                  WHEN 4 THEN 'Insurance Payments'
                  WHEN 7 THEN 'Insurance Adjustments'
                  ELSE 'Type ' || TO_CHAR(d."Type") END AS "Section",
    NVL(TRIM(d."ReportPGroup"), 'No Provider Group')    AS "Provider Group",
    SUM(CASE WHEN d."Type" IN (3, 4, 7)
             THEN - d."ReportTotalChange"
             ELSE d."ReportTotalChange" END)            AS "Amount"
FROM axium.ar_recon_saved_data_dtl d
WHERE d."Batch" = (
        SELECT MAX(h."Batch")
        FROM axium.ar_recon_saved_data_hdr h
        WHERE h."GroupBy1" = 2
          AND h."IsDetailed" = 0
          AND h."FromDate" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
          AND h."FromDate" <  TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM') + 1
          AND h."ToDate"   >= TRUNC(SYSDATE, 'MM') - 1
          AND EXISTS (SELECT 1 FROM axium.ar_recon_saved_data_dtl x
                      WHERE x."Batch" = h."Batch"))
  AND NVL(d."ReportHistoryTypeDescription", 'x') NOT IN
      ('Unallocated Adjustments', 'Unallocated Insurance Payments', 'Unallocated Payments')
GROUP BY
    CASE d."Type" WHEN 1 THEN 'Treatments'
                  WHEN 2 THEN 'Treatments'
                  WHEN 3 THEN 'Patient Payments'
                  WHEN 6 THEN 'Patient Adjustments'
                  WHEN 4 THEN 'Insurance Payments'
                  WHEN 7 THEN 'Insurance Adjustments'
                  ELSE 'Type ' || TO_CHAR(d."Type") END,
    NVL(TRIM(d."ReportPGroup"), 'No Provider Group')
ORDER BY 1, 2


-- ============================================================================
-- QUERY 13: A/R "as at" balance lines for the same auto-selected batch
-- BeginningBalance = "A/R as at <FromDate>", EndingBalance = "A/R as at <ToDate>"
-- ============================================================================
SELECT
    h."Batch",
    h."FromDate",
    h."ToDate",
    h."BeginningBalance" AS "AR Opening",
    h."EndingBalance"    AS "AR Closing"
FROM axium.ar_recon_saved_data_hdr h
WHERE h."Batch" = (
        SELECT MAX(h2."Batch")
        FROM axium.ar_recon_saved_data_hdr h2
        WHERE h2."GroupBy1" = 2
          AND h2."IsDetailed" = 0
          AND h2."FromDate" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
          AND h2."FromDate" <  TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM') + 1
          AND h2."ToDate"   >= TRUNC(SYSDATE, 'MM') - 1
          AND EXISTS (SELECT 1 FROM axium.ar_recon_saved_data_dtl x
                      WHERE x."Batch" = h2."Batch"))


-- ============================================================================
-- =============  LIVE HISTORY-BASED RECREATION (NO AXIUM RUN)  ===============
-- Validated penny-exact against the Aug 2026 printout:
--   Treatments 3,606,892.47 / Pt Pmts -655,400.89 / Pt Adj -200,152.32 /
--   Ins Pmts -2,029,388.79 / Ins Adj -1,810,128.16  (all five EXACT).
-- Engine rules, reverse-engineered from axium.HISTORY (the immutable audit
-- trail - one full TRX snapshot per change, period = ModifiedDate):
--   * Ledger amount of a charge version: 0 if deleted; else Total for an
--     office charge (Type 2) or a treatment with Status C or I; else 0.
--   * Treatments section = sum of ledger-amount deltas between consecutive
--     versions of each charge, over events in the period.
--   * The four payment sections = deltas of the charge's Payed / InsPayed /
--     PtAdj / InsAdj allocation fields, summed over allocation events
--     (HistoryType 3) plus all office-charge (Type 2) events; Payed,
--     InsPayed and InsAdj are negated for display parity with the printout.
--   * Grouping: the snapshot's Producer -> PRODUCER.PGroup. (A producer
--     change mid-period attributes its delta to the new group; the printout
--     splits it as Transfer In/Out between groups - same net, +/-3,884 in Aug.)
-- These scan ~35M history rows with window functions: expect a few minutes.
-- ============================================================================


-- ============================================================================
-- QUERY 14: REPORT BODY, LIVE FROM HISTORY (previous calendar month)
-- One row per provider group with all five sections as columns.
-- To pin a month, replace the two TRUNC expressions with literals, e.g.
--   DATE '2026-08-01' and DATE '2026-09-01'.
-- ============================================================================
WITH ev AS (
    SELECT h."Type"         AS typ,
           h."HistoryType"  AS ht,
           h."ModifiedDate" AS md,
           TRIM(h."Producer") AS prod,
           CASE WHEN NVL(h."Deleted",0) <> 0 THEN 0
                WHEN h."Type" = 2 OR TRIM(h."Status") IN ('C','I') THEN NVL(h."Total",0)
                ELSE 0 END AS led,
           LAG(CASE WHEN NVL(h."Deleted",0) <> 0 THEN 0
                WHEN h."Type" = 2 OR TRIM(h."Status") IN ('C','I') THEN NVL(h."Total",0)
                ELSE 0 END) OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS pled,
           NVL(h."Payed",0)    AS pay,
           LAG(NVL(h."Payed",0))    OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS ppay,
           NVL(h."InsPayed",0) AS ipay,
           LAG(NVL(h."InsPayed",0)) OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS pipay,
           NVL(h."PtAdj",0)    AS padj,
           LAG(NVL(h."PtAdj",0))    OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS ppadj,
           NVL(h."InsAdj",0)   AS iadj,
           LAG(NVL(h."InsAdj",0))   OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS piadj
    FROM axium.history h
    WHERE h."Type" IN (1, 2)
)
SELECT NVL(TRIM(p."PGroup"), 'No Provider Group') AS "Provider Group",
       SUM(led - NVL(pled,0))                     AS "Treatments",
       - SUM(CASE WHEN ht = 3 OR typ = 2 THEN pay  - NVL(ppay,0)  ELSE 0 END) AS "Patient Payments",
       SUM(CASE WHEN ht = 3 OR typ = 2 THEN padj - NVL(ppadj,0) ELSE 0 END)   AS "Patient Adjustments",
       - SUM(CASE WHEN ht = 3 OR typ = 2 THEN ipay - NVL(pipay,0) ELSE 0 END) AS "Insurance Payments",
       - SUM(CASE WHEN ht = 3 OR typ = 2 THEN iadj - NVL(piadj,0) ELSE 0 END) AS "Insurance Adjustments"
FROM ev
LEFT JOIN axium.producer p
       ON TRIM(p."Producer") = ev.prod
WHERE ev.md >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND ev.md <  TRUNC(SYSDATE, 'MM')
GROUP BY NVL(TRIM(p."PGroup"), 'No Provider Group')
ORDER BY 1


-- ============================================================================
-- QUERY 15: A/R "as at" BALANCES, LIVE FROM HISTORY
-- Opening = cumulative ledger deltas before the month start;
-- Closing  = before the month end. Validation targets for August 2026:
--   Opening 20,816,258.52 / Closing 19,728,080.83.
-- ============================================================================
WITH ev AS (
    SELECT h."ModifiedDate" AS md,
           CASE WHEN NVL(h."Deleted",0) <> 0 THEN 0
                WHEN h."Type" = 2 OR TRIM(h."Status") IN ('C','I') THEN NVL(h."Total",0)
                ELSE 0 END AS led,
           LAG(CASE WHEN NVL(h."Deleted",0) <> 0 THEN 0
                WHEN h."Type" = 2 OR TRIM(h."Status") IN ('C','I') THEN NVL(h."Total",0)
                ELSE 0 END) OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS pled,
           NVL(h."Payed",0) + NVL(h."InsPayed",0) + NVL(h."InsAdj",0) - NVL(h."PtAdj",0) AS alloc,
           LAG(NVL(h."Payed",0) + NVL(h."InsPayed",0) + NVL(h."InsAdj",0) - NVL(h."PtAdj",0))
               OVER (PARTITION BY h."Type", h."Id", h."Treatment" ORDER BY h."History") AS palloc,
           h."HistoryType" AS ht,
           h."Type" AS typ
    FROM axium.history h
    WHERE h."Type" IN (1, 2)
)
SELECT SUM(CASE WHEN md < TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
               THEN (led - NVL(pled,0))
                    - (CASE WHEN ht = 3 OR typ = 2 THEN alloc - NVL(palloc,0) ELSE 0 END)
               ELSE 0 END) AS "AR Opening",
       SUM((led - NVL(pled,0))
           - (CASE WHEN ht = 3 OR typ = 2 THEN alloc - NVL(palloc,0) ELSE 0 END)) AS "AR Closing"
FROM ev
WHERE md < TRUNC(SYSDATE, 'MM')
