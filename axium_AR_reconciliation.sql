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
-- SIGN CHECK: if payment sections come back POSITIVE, ALLOCATE."Amount" is
--   stored with the opposite sign in your database. Fix: change
--   "- a."Amount""  to  "a."Amount""  in the second branch, and
--   "+ NVL(al."Allocated", 0)"  to  "- NVL(al."Allocated", 0)"  in the third.
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
        - a."Amount"
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
        pay."Total" + NVL(al."Allocated", 0)
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
