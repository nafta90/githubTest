-- ============================================================================
-- axiUm VISITS & TREATMENTS REPORT
-- Companion to axium_AR_reconciliation.sql (same DSN "axiUm DB", Oracle,
-- user fin_powerbi_readonly). Built only on tables that account is already
-- using: AXIUM.TRX, AXIUM.PRODUCER, AXIUM.PATIENT.
--
-- The report period defaults to the PREVIOUS FULL CALENDAR MONTH
-- (run it any time during September and you get August, etc.).
-- To pin a specific month instead, replace the two date expressions:
--     TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')  -->  DATE '2026-08-01'
--     TRUNC(SYSDATE, 'MM')                  -->  DATE '2026-09-01'
--
-- DEFINITIONS (documented so Finance and the clinics agree on the numbers):
--   * TREATMENT  = a TRX row with "Type" = 1. Status codes (from the
--     validated history engine in the A/R work): 'C' = completed,
--     'I' = in process; only those two statuses hit the ledger. Planned/
--     other statuses are excluded from counts and value here.
--   * TREATMENT VALUE = SUM(TRX."Total") of the counted treatments
--     (the posted fee, same figure the A/R report's Treatments section uses).
--   * VISIT = a distinct PATIENT + SERVICE DAY (TRUNC(TRX."Date")) that has
--     at least one countable row: a completed/in-process treatment (Type 1,
--     Status C/I) or an office charge (Type 2). This is activity-based, not
--     appointment-based: no-shows and visits with nothing posted don't count.
--     (An appointment-based version needs SELECT on axiUm's scheduler tables,
--     which this account has not been granted - ask the DBA if needed.)
--   * Rows with NVL("Deleted",0) <> 0 are always excluded.
--     Rows with NVL("Suspended",0) = 1 (pending approval) are excluded too,
--     matching the printed A/R report; delete that line in each query if you
--     want suspended work included.
--   * Date basis = TRX."Date" (service/transaction date), the same basis as
--     the live A/R queries. Swap in "CreationDate" for an entry-date view.
--   * Provider Group = PRODUCER."PGroup" of the transaction's own producer
--     (treatments carry a producer, so no allocation logic is needed here).
--
-- GRAND-TOTAL CAVEAT: visits are counted within each grouping. A patient
-- seen by two provider groups on the same day is one visit in each group,
-- so the sum of group visit counts can exceed the clinic-wide count from
-- Query V2. That is expected; use V2 for the official clinic total.
--
-- EXCEL PASTING RULE (avoids ODBC error ORA-24374):
--   Copy ONLY the bare statement, from the word SELECT (or WITH) down to the
--   last line of the query. Do NOT include any comment lines, and the
--   statement must NOT end with a semicolon.
-- ============================================================================


-- ============================================================================
-- QUERY V1: MONTHLY SUMMARY BY PROVIDER GROUP (previous calendar month)
-- One row per provider group:
--   Visits | Unique Patients | Completed Tx | In-Process Tx |
--   Completed Value | In-Process Value | Avg Completed Value per Visit
-- ============================================================================
SELECT
    NVL(TRIM(p."PGroup"), 'No Provider Group')          AS "Provider Group",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN TO_CHAR(t."Patient") || '|'
                             || TO_CHAR(TRUNC(t."Date"), 'YYYYMMDD') END)
                                                        AS "Visits",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN t."Patient" END)           AS "Unique Patients",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'C' THEN 1 END)  AS "Completed Treatments",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'I' THEN 1 END)  AS "In-Process Treatments",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'C'
             THEN t."Total" ELSE 0 END)                 AS "Completed Value",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'I'
             THEN t."Total" ELSE 0 END)                 AS "In-Process Value",
    ROUND(
        SUM(CASE WHEN t."Type" = 1 AND TRIM(t."Status") = 'C'
                 THEN t."Total" ELSE 0 END)
        / NULLIF(COUNT(DISTINCT CASE WHEN t."Type" = 2
                                       OR TRIM(t."Status") IN ('C', 'I')
                                     THEN TO_CHAR(t."Patient") || '|'
                                          || TO_CHAR(TRUNC(t."Date"), 'YYYYMMDD') END), 0)
    , 2)                                                AS "Avg Completed Value / Visit"
FROM axium.trx t
LEFT JOIN axium.producer p
       ON p."Producer" = t."Producer"
WHERE t."Type" IN (1, 2)
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY NVL(TRIM(p."PGroup"), 'No Provider Group')
ORDER BY 1


-- ============================================================================
-- QUERY V2: CLINIC-WIDE TOTALS (previous calendar month)
-- One row. Visits/patients counted across the whole clinic, so a patient
-- seen by several groups the same day counts once - this is the official
-- total; group figures in V1 can sum slightly higher.
-- ============================================================================
SELECT
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN TO_CHAR(t."Patient") || '|'
                             || TO_CHAR(TRUNC(t."Date"), 'YYYYMMDD') END)
                                                        AS "Visits",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN t."Patient" END)           AS "Unique Patients",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'C' THEN 1 END)  AS "Completed Treatments",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'I' THEN 1 END)  AS "In-Process Treatments",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'C'
             THEN t."Total" ELSE 0 END)                 AS "Completed Value"
FROM axium.trx t
WHERE t."Type" IN (1, 2)
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')


-- ============================================================================
-- QUERY V3: ALL MONTHS AT ONCE - Month x Provider Group trend
-- Same columns as V1 for every month in one result set; feed it to a pivot
-- table for multi-year trend analysis (companion to A/R Query 16).
-- Narrow the date floor in the WHERE clause if you only want recent years.
-- ============================================================================
SELECT
    TRUNC(t."Date", 'MM')                               AS "Month",
    NVL(TRIM(p."PGroup"), 'No Provider Group')          AS "Provider Group",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN TO_CHAR(t."Patient") || '|'
                             || TO_CHAR(TRUNC(t."Date"), 'YYYYMMDD') END)
                                                        AS "Visits",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN t."Patient" END)           AS "Unique Patients",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'C' THEN 1 END)  AS "Completed Treatments",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'I' THEN 1 END)  AS "In-Process Treatments",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'C'
             THEN t."Total" ELSE 0 END)                 AS "Completed Value"
FROM axium.trx t
LEFT JOIN axium.producer p
       ON p."Producer" = t."Producer"
WHERE t."Type" IN (1, 2)
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND t."Date" >= DATE '2020-01-01'
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY TRUNC(t."Date", 'MM'), NVL(TRIM(p."PGroup"), 'No Provider Group')
ORDER BY 1, 2


-- ============================================================================
-- QUERY V4: TREATMENTS BY PROCEDURE CODE (previous calendar month)
-- Completed treatments only, ranked by billed value. "Code" is the ADA/CDT
-- procedure code on the transaction; Description is taken from the rows.
-- ============================================================================
SELECT
    TRIM(t."Code")                        AS "Procedure Code",
    MIN(t."Description")                  AS "Description",
    COUNT(*)                              AS "Count",
    SUM(t."Total")                        AS "Total Value",
    ROUND(AVG(t."Total"), 2)              AS "Avg Fee"
FROM axium.trx t
WHERE t."Type" = 1
  AND TRIM(t."Status") = 'C'
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY TRIM(t."Code")
ORDER BY SUM(t."Total") DESC


-- ============================================================================
-- QUERY V5: PER-PROVIDER PRODUCTIVITY (previous calendar month)
-- One row per producer: their group, visits they saw, completed/in-process
-- treatment counts and completed value. PRODUCER name columns were not in
-- the verified dictionary extract - if the data dictionary shows name
-- columns (e.g. "LastName"/"FirstName"), add them to the SELECT and GROUP BY.
-- ============================================================================
SELECT
    TRIM(t."Producer")                                  AS "Producer",
    NVL(TRIM(p."PGroup"), 'No Provider Group')          AS "Provider Group",
    COUNT(DISTINCT CASE WHEN t."Type" = 2
                          OR TRIM(t."Status") IN ('C', 'I')
                        THEN TO_CHAR(t."Patient") || '|'
                             || TO_CHAR(TRUNC(t."Date"), 'YYYYMMDD') END)
                                                        AS "Visits",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'C' THEN 1 END)  AS "Completed Treatments",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") = 'I' THEN 1 END)  AS "In-Process Treatments",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'C'
             THEN t."Total" ELSE 0 END)                 AS "Completed Value"
FROM axium.trx t
LEFT JOIN axium.producer p
       ON p."Producer" = t."Producer"
WHERE t."Type" IN (1, 2)
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY TRIM(t."Producer"), NVL(TRIM(p."PGroup"), 'No Provider Group')
ORDER BY "Completed Value" DESC


-- ============================================================================
-- QUERY V6: VISIT DETAIL (previous calendar month)
-- One row per patient visit per provider group:
--   Date | Patient | Provider Group | Procedures | Completed Value
-- CONTAINS PHI - keep the output inside your normal reporting controls.
-- ============================================================================
SELECT
    TRUNC(t."Date")                                     AS "Visit Date",
    TRIM(pt."Last") || ', ' || TRIM(pt."First")         AS "Patient",
    NVL(TRIM(p."PGroup"), 'No Provider Group')          AS "Provider Group",
    COUNT(CASE WHEN t."Type" = 1
                AND TRIM(t."Status") IN ('C', 'I') THEN 1 END)
                                                        AS "Procedures",
    SUM(CASE WHEN t."Type" = 1
              AND TRIM(t."Status") = 'C'
             THEN t."Total" ELSE 0 END)                 AS "Completed Value"
FROM axium.trx t
LEFT JOIN axium.producer p
       ON p."Producer" = t."Producer"
LEFT JOIN axium.patient pt
       ON pt."Patient" = t."Patient"
WHERE t."Type" IN (1, 2)
  AND NVL(t."Deleted", 0) = 0
  AND NVL(t."Suspended", 0) = 0
  AND (t."Type" = 2 OR TRIM(t."Status") IN ('C', 'I'))
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY TRUNC(t."Date"),
         TRIM(pt."Last") || ', ' || TRIM(pt."First"),
         NVL(TRIM(p."PGroup"), 'No Provider Group')
ORDER BY 1, 2


-- ============================================================================
-- QUERY V7: FIRST-RUN DIAGNOSTIC - treatment status distribution
-- Run this once for the period before trusting V1-V6: it shows every
-- Type-1 status present with row counts and value, so you can confirm that
-- 'C' and 'I' are the right statuses to count at your site (and see how much
-- sits in planned/other statuses that the report excludes).
-- ============================================================================
SELECT
    TRIM(t."Status")                   AS "Status",
    NVL(t."Suspended", 0)              AS "Suspended",
    COUNT(*)                           AS "Rows",
    SUM(t."Total")                     AS "Total Value"
FROM axium.trx t
WHERE t."Type" = 1
  AND NVL(t."Deleted", 0) = 0
  AND t."Date" >= TRUNC(ADD_MONTHS(SYSDATE, -1), 'MM')
  AND t."Date" <  TRUNC(SYSDATE, 'MM')
GROUP BY TRIM(t."Status"), NVL(t."Suspended", 0)
ORDER BY 1, 2
