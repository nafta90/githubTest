/* =============================================================================
   VENDOR ACTIVITY SUMMARY
   =============================================================================
   Source      : Finance EDW (Banner Decision Support physical model)
   Platform    : Oracle (no bind variables -- ODBC/Power Query safe)
   Grain       : 1 row per VENDOR. Fast companion to the detail report
                 (sql/vendor_activity_report.sql): browse vendors here, then
                 run the detail query with vend_id set to drill in.

   Parameters: edit the PARAMS block below.
     start_dt  DATE      - DEFAULT rolling past 2 years; NULL = all history.
     end_dt    DATE      - NULL = no upper bound.
     coll_cd   VARCHAR2  - college code (COLL_LEVEL_3_CD), default 'FN'.

   Amounts:
     - TOTAL_INVOICED_AMT sums the FOAP-distribution net amounts
       (T_INV_VCHR_ACCTG_DETL), so split distributions never double-count.
     - TOTAL_PAID_AMT sums check gross amounts applied to those same
       distributions. UNPAID_AMT = invoiced - paid is approximate: taxes,
       discounts and withholding can make the two bases differ slightly.
     - Cancelled invoices are EXCLUDED from amount totals but counted in
       CNCL_INV_COUNT so they stay visible.
   ========================================================================== */

WITH params AS (
    SELECT
        ADD_MONTHS(TRUNC(SYSDATE), -24) AS start_dt,  -- past 2 years
        CAST(NULL AS DATE)              AS end_dt,
        'FN'                            AS coll_cd    -- Dentistry
    FROM dual
),
dist AS (
    /* In-scope invoice FOAP distributions for the college + date window. */
    SELECT
        iv.INV_VCHR_VEND_EDW_PARTY_ID                AS VEND_EDW_PARTY_ID,
        iv.INV_VCHR_VEND_NAME,
        iv.EDW_FIN_DOC_ID,
        iv.PO_EDW_FIN_DOC_ID,
        iv.INV_VCHR_DT,
        iv.CREDMEM_IND,
        iv.INV_VCHR_CNCL_IND,
        ad.INV_VCHR_LINE_ITEM_NBR,
        ad.INV_VCHR_SEQ_NBR,
        ad.INV_VCHR_ACCTG_DETL_NET_AMT               AS DETL_NET_AMT
    FROM  T_INV_VCHR iv
    JOIN  T_INV_VCHR_ACCTG_DETL ad
          ON  ad.EDW_FIN_DOC_ID = iv.EDW_FIN_DOC_ID
    JOIN  T_ORG_CD_HIST org
          ON  org.COA_CD = ad.COA_CD
          AND org.ORG_CD = ad.ORG_CD
          AND org.ORG_CD_CUR_INFO_IND = 'Y'
    CROSS JOIN params prm
    WHERE org.COLL_LEVEL_3_CD = NVL(prm.coll_cd, 'FN')
      AND ( prm.start_dt IS NULL OR iv.INV_VCHR_DT >= prm.start_dt )
      AND ( prm.end_dt   IS NULL OR iv.INV_VCHR_DT <  prm.end_dt + 1 )
),
pay AS (
    /* Check payments for the same date window, at distribution grain. */
    SELECT
        bcd.INV_VCHR_EDW_FIN_DOC_ID,
        bcd.INV_VCHR_LINE_ITEM_NBR,
        bcd.INV_VCHR_SEQ_NBR,
        SUM(bcd.BANK_CHK_INV_VCHR_GROSS_AMT)         AS PAID_GROSS_AMT,
        MAX(bc.BANK_CHK_DT)                          AS LAST_CHK_DT,
        COUNT(DISTINCT bcd.BANK_CHECK_EDW_FIN_DOC_ID
                       || '~' || bcd.BANK_CHK_BANK_CD)
                                                     AS CHK_COUNT
    FROM  T_BANK_CHK_INV_VCHR_DETL bcd
    JOIN  T_INV_VCHR pinv
          ON  pinv.EDW_FIN_DOC_ID = bcd.INV_VCHR_EDW_FIN_DOC_ID
    CROSS JOIN params prm
    JOIN  T_BANK_CHK bc
          ON  bc.EDW_FIN_DOC_ID   = bcd.BANK_CHECK_EDW_FIN_DOC_ID
          AND bc.BANK_CHK_BANK_CD = bcd.BANK_CHK_BANK_CD
    WHERE ( prm.start_dt IS NULL OR pinv.INV_VCHR_DT >= prm.start_dt )
      AND ( prm.end_dt   IS NULL OR pinv.INV_VCHR_DT <  prm.end_dt + 1 )
    GROUP BY
        bcd.INV_VCHR_EDW_FIN_DOC_ID,
        bcd.INV_VCHR_LINE_ITEM_NBR,
        bcd.INV_VCHR_SEQ_NBR
)
SELECT
    v.VEND_ID,
    COALESCE(v.VEND_NAME, d.INV_VCHR_VEND_NAME)              AS VEND_NAME,
    v.INCM_TYPE_CD                                           AS VEND_INCM_TYPE_CD,
    v.VEND_INSTATE_IND,
    v.VEND_BUS_STATE_CD,
    /* ----- activity counts ----- */
    COUNT(DISTINCT d.EDW_FIN_DOC_ID)                         AS INV_COUNT,
    COUNT(DISTINCT CASE WHEN d.CREDMEM_IND = 'Y'
                        THEN d.EDW_FIN_DOC_ID END)           AS CREDIT_MEMO_COUNT,
    COUNT(DISTINCT CASE WHEN d.INV_VCHR_CNCL_IND = 'Y'
                        THEN d.EDW_FIN_DOC_ID END)           AS CNCL_INV_COUNT,
    COUNT(DISTINCT d.PO_EDW_FIN_DOC_ID)                      AS PO_COUNT,
    SUM(pay.CHK_COUNT)                                       AS CHK_COUNT,
    /* ----- dates ----- */
    MIN(d.INV_VCHR_DT)                                       AS FIRST_INV_DT,
    MAX(d.INV_VCHR_DT)                                       AS LAST_INV_DT,
    MAX(pay.LAST_CHK_DT)                                     AS LAST_CHK_DT,
    /* ----- amounts (cancelled invoices excluded) ----- */
    SUM(CASE WHEN d.INV_VCHR_CNCL_IND = 'Y' THEN 0
             ELSE d.DETL_NET_AMT END)                        AS TOTAL_INVOICED_AMT,
    SUM(CASE WHEN d.INV_VCHR_CNCL_IND = 'Y' THEN 0
             ELSE NVL(pay.PAID_GROSS_AMT, 0) END)            AS TOTAL_PAID_AMT,
    SUM(CASE WHEN d.INV_VCHR_CNCL_IND = 'Y' THEN 0
             ELSE d.DETL_NET_AMT - NVL(pay.PAID_GROSS_AMT, 0) END)
                                                             AS UNPAID_AMT
FROM  dist d
LEFT JOIN pay
      ON  pay.INV_VCHR_EDW_FIN_DOC_ID = d.EDW_FIN_DOC_ID
      AND pay.INV_VCHR_LINE_ITEM_NBR  = d.INV_VCHR_LINE_ITEM_NBR
      AND pay.INV_VCHR_SEQ_NBR        = d.INV_VCHR_SEQ_NBR
LEFT JOIN T_VEND v
      ON  v.EDW_PARTY_ID = d.VEND_EDW_PARTY_ID
GROUP BY
    v.VEND_ID,
    COALESCE(v.VEND_NAME, d.INV_VCHR_VEND_NAME),  -- keeps one-time vendors distinct
    v.INCM_TYPE_CD,
    v.VEND_INSTATE_IND,
    v.VEND_BUS_STATE_CD
ORDER BY
    TOTAL_INVOICED_AMT DESC
