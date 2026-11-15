/* =============================================================================
   VENDOR INVOICE EXCEPTIONS (on hold / stuck / payment problems)
   =============================================================================
   Source      : Finance EDW (Banner Decision Support physical model)
   Platform    : Oracle (no bind variables -- ODBC/Power Query safe)
   Grain       : 1 row per INVOICE (line items, FOAP distributions and checks
                 are aggregated up). Companion to:
                   - sql/vendor_activity_report.sql  (full detail)
                   - sql/vendor_activity_summary.sql (per-vendor totals)

   What counts as an "issue" (each one is named in ISSUE_LIST):
     HEADER HOLD              - INV_VCHR_HOLD_IND = 'Y'
     LINE HOLD                - any line item with HOLD_IND = 'Y'
     PAST DUE                 - unpaid/underpaid and PMT_DUE_DT < today
     SITTING UNPAID           - no payment and invoice older than
                                params.sitting_days (default 30)
     PARTIALLY PAID           - some but not all of the net amount paid
     CHECK CANCELLED-NOT REPAID - a check was cancelled and the invoice is
                                still not fully paid
     RECEIVING INCOMPLETE     - matching required and received qty < invoiced
                                qty on at least one line

   About "rejected": documents rejected/incomplete in Banner approvals
   normally never post to the EDW, so they cannot appear here. The closest
   posted-side signals are the holds above plus DOC_POST_STATUS_IND
   (T_POST_DOC.POST_DOC_STATUS_IND, exposed raw -- check your site's code
   values for anything other than approved/posted).

   Status fields:
     INVOICE_STATUS  (derived) - CANCELLED / ON HOLD / OPEN / CLOSED-PAID
     PAYMENT_STATUS  (derived) - PAID IN FULL / PARTIALLY PAID / UNPAID
     INV_OPEN_PD_IND (raw)     - EDW open/paid indicator on the invoice
     DOC_POST_STATUS_IND (raw) - posted-document status indicator

   Default scope: only invoices with at least one issue, cancelled invoices
   excluded, past 2 years, college FN. See the two "TOGGLE" comments to
   include cancelled invoices or to list every open invoice instead.
   ========================================================================== */

WITH params AS (
    SELECT
        ADD_MONTHS(TRUNC(SYSDATE), -24) AS start_dt,     -- past 2 years
        CAST(NULL AS DATE)              AS end_dt,
        'FN'                            AS coll_cd,      -- Dentistry
        CAST(NULL AS VARCHAR2(30))      AS vend_id,
        30                              AS sitting_days  -- unpaid-age threshold
    FROM dual
),
scope AS (
    /* In-scope invoices: college + date window (+ optional vendor). */
    SELECT DISTINCT
        iv.EDW_FIN_DOC_ID
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
      /* TOGGLE: delete the next line to include cancelled invoices */
      AND NVL(iv.INV_VCHR_CNCL_IND, 'N') <> 'Y'
),
li_sum AS (
    /* Line-item flags rolled up per invoice. */
    SELECT
        li.EDW_FIN_DOC_ID,
        COUNT(*)                                            AS LINE_CNT,
        SUM(CASE WHEN li.INV_VCHR_LINE_ITEM_HOLD_IND = 'Y'
                 THEN 1 ELSE 0 END)                         AS HELD_LINE_CNT,
        SUM(CASE WHEN NVL(li.INV_VCHR_LINE_ITEM_RCVD_QTY, 0)
                      < NVL(li.INV_VCHR_LINE_ITEM_INV_QTY, 0)
                 THEN 1 ELSE 0 END)                         AS RCV_SHORT_LINE_CNT
    FROM  T_INV_VCHR_LINE_ITEM li
    JOIN  scope s ON s.EDW_FIN_DOC_ID = li.EDW_FIN_DOC_ID
    GROUP BY li.EDW_FIN_DOC_ID
),
ad_sum AS (
    /* FOAP distributions rolled up per invoice (authoritative net amount). */
    SELECT
        ad.EDW_FIN_DOC_ID,
        SUM(ad.INV_VCHR_ACCTG_DETL_NET_AMT)                 AS INVOICED_NET_AMT,
        COUNT(*)                                            AS DIST_CNT,
        SUM(CASE WHEN ad.INV_VCHR_ACCTG_DETL_PD_IND = 'Y'
                 THEN 1 ELSE 0 END)                         AS PAID_FLAG_DIST_CNT
    FROM  T_INV_VCHR_ACCTG_DETL ad
    JOIN  scope s ON s.EDW_FIN_DOC_ID = ad.EDW_FIN_DOC_ID
    GROUP BY ad.EDW_FIN_DOC_ID
),
pay_sum AS (
    /* Check activity rolled up per invoice. */
    SELECT
        bcd.INV_VCHR_EDW_FIN_DOC_ID                         AS EDW_FIN_DOC_ID,
        SUM(CASE WHEN NVL(bc.BANK_CHK_CNCL_IND, 'N') <> 'Y'
                 THEN bcd.BANK_CHK_INV_VCHR_GROSS_AMT
                 ELSE 0 END)                                AS PAID_GROSS_AMT,
        COUNT(DISTINCT bcd.BANK_CHECK_EDW_FIN_DOC_ID
                       || '~' || bcd.BANK_CHK_BANK_CD)      AS CHK_CNT,
        COUNT(DISTINCT CASE WHEN bc.BANK_CHK_CNCL_IND = 'Y'
                            THEN bcd.BANK_CHECK_EDW_FIN_DOC_ID
                                 || '~' || bcd.BANK_CHK_BANK_CD END)
                                                            AS CNCL_CHK_CNT,
        MAX(bc.BANK_CHK_DT)                                 AS LAST_CHK_DT,
        LISTAGG(chkdoc.POST_DOC_NBR
                || CASE WHEN bc.BANK_CHK_CNCL_IND = 'Y'
                        THEN ' (CNCL)' END, '; ')
            WITHIN GROUP (ORDER BY bc.BANK_CHK_DT)          AS CHK_NBR_LIST
    FROM  T_BANK_CHK_INV_VCHR_DETL bcd
    JOIN  scope s ON s.EDW_FIN_DOC_ID = bcd.INV_VCHR_EDW_FIN_DOC_ID
    JOIN  T_BANK_CHK bc
          ON  bc.EDW_FIN_DOC_ID   = bcd.BANK_CHECK_EDW_FIN_DOC_ID
          AND bc.BANK_CHK_BANK_CD = bcd.BANK_CHK_BANK_CD
    LEFT JOIN T_POST_DOC chkdoc
          ON  chkdoc.EDW_FIN_DOC_ID = bcd.BANK_CHECK_EDW_FIN_DOC_ID
    GROUP BY bcd.INV_VCHR_EDW_FIN_DOC_ID
),
rpt AS (
    SELECT
        /* ------------------------- VENDOR --------------------------- */
        v.VEND_ID,
        COALESCE(v.VEND_NAME, iv.INV_VCHR_VEND_NAME)        AS VEND_NAME,
        /* ------------------------- INVOICE -------------------------- */
        invdoc.POST_DOC_NBR                                 AS INV_DOC_NBR,
        iv.VEND_INV_NBR,
        iv.INV_VCHR_DT,
        iv.INV_VCHR_PMT_DUE_DT,
        iv.INV_VCHR_POST_DT,
        podoc.POST_DOC_NBR                                  AS PO_NBR,
        ads.INVOICED_NET_AMT,
        NVL(ps.PAID_GROSS_AMT, 0)                           AS PAID_AMT,
        ads.INVOICED_NET_AMT - NVL(ps.PAID_GROSS_AMT, 0)    AS UNPAID_AMT,
        /* ---------------------- STATUS FIELDS ----------------------- */
        CASE
            WHEN iv.INV_VCHR_CNCL_IND = 'Y'               THEN 'CANCELLED'
            WHEN iv.INV_VCHR_HOLD_IND = 'Y'
                 OR NVL(lis.HELD_LINE_CNT, 0) > 0         THEN 'ON HOLD'
            WHEN iv.INV_VCHR_OPEN_PD_IND = 'P'            THEN 'CLOSED-PAID'
            WHEN iv.INV_VCHR_OPEN_PD_IND = 'O'            THEN 'OPEN'
            ELSE 'OPEN (' || NVL(iv.INV_VCHR_OPEN_PD_IND, '?') || ')'
        END                                                 AS INVOICE_STATUS,
        CASE
            WHEN NVL(ps.PAID_GROSS_AMT, 0) >= ads.INVOICED_NET_AMT - 0.01
                 AND ads.INVOICED_NET_AMT > 0             THEN 'PAID IN FULL'
            WHEN NVL(ps.PAID_GROSS_AMT, 0) > 0            THEN 'PARTIALLY PAID'
            ELSE 'UNPAID'
        END                                                 AS PAYMENT_STATUS,
        iv.INV_VCHR_OPEN_PD_IND                             AS INV_OPEN_PD_IND,
        invdoc.POST_DOC_STATUS_IND                          AS DOC_POST_STATUS_IND,
        iv.INV_VCHR_HOLD_IND                                AS INV_HOLD_IND,
        NVL(lis.HELD_LINE_CNT, 0)                           AS HELD_LINE_CNT,
        iv.INV_VCHR_MATCH_REQRD_IND,
        NVL(lis.RCV_SHORT_LINE_CNT, 0)                      AS RCV_SHORT_LINE_CNT,
        iv.CREDMEM_IND,
        /* ------------------------- AGING ----------------------------- */
        TRUNC(SYSDATE) - TRUNC(iv.INV_VCHR_DT)              AS DAYS_SINCE_INV,
        CASE WHEN iv.INV_VCHR_PMT_DUE_DT IS NOT NULL
             THEN TRUNC(SYSDATE) - TRUNC(iv.INV_VCHR_PMT_DUE_DT)
        END                                                 AS DAYS_PAST_DUE,
        /* ------------------------ PAYMENTS --------------------------- */
        NVL(ps.CHK_CNT, 0)                                  AS CHK_CNT,
        NVL(ps.CNCL_CHK_CNT, 0)                             AS CNCL_CHK_CNT,
        ps.LAST_CHK_DT,
        ps.CHK_NBR_LIST,
        /* ------------------------ ISSUE LIST -------------------------- */
        LTRIM(
            CASE WHEN iv.INV_VCHR_HOLD_IND = 'Y'
                 THEN '; HEADER HOLD' END
         || CASE WHEN NVL(lis.HELD_LINE_CNT, 0) > 0
                 THEN '; LINE HOLD (' || lis.HELD_LINE_CNT || ')' END
         || CASE WHEN NVL(ps.PAID_GROSS_AMT, 0) < ads.INVOICED_NET_AMT - 0.01
                      AND iv.INV_VCHR_PMT_DUE_DT < TRUNC(SYSDATE)
                 THEN '; PAST DUE ('
                      || (TRUNC(SYSDATE) - TRUNC(iv.INV_VCHR_PMT_DUE_DT))
                      || ' DAYS)' END
         || CASE WHEN NVL(ps.PAID_GROSS_AMT, 0) = 0
                      AND ads.INVOICED_NET_AMT > 0
                      AND iv.INV_VCHR_DT < TRUNC(SYSDATE) - prm.sitting_days
                 THEN '; SITTING UNPAID > ' || prm.sitting_days || ' DAYS' END
         || CASE WHEN NVL(ps.PAID_GROSS_AMT, 0) > 0
                      AND NVL(ps.PAID_GROSS_AMT, 0)
                          < ads.INVOICED_NET_AMT - 0.01
                 THEN '; PARTIALLY PAID' END
         || CASE WHEN NVL(ps.CNCL_CHK_CNT, 0) > 0
                      AND NVL(ps.PAID_GROSS_AMT, 0)
                          < ads.INVOICED_NET_AMT - 0.01
                 THEN '; CHECK CANCELLED-NOT REPAID' END
         || CASE WHEN iv.INV_VCHR_MATCH_REQRD_IND = 'Y'
                      AND NVL(lis.RCV_SHORT_LINE_CNT, 0) > 0
                 THEN '; RECEIVING INCOMPLETE ('
                      || lis.RCV_SHORT_LINE_CNT || ' LINES)' END,
            '; ')                                           AS ISSUE_LIST
    FROM  scope s
    JOIN  T_INV_VCHR iv       ON iv.EDW_FIN_DOC_ID = s.EDW_FIN_DOC_ID
    JOIN  ad_sum ads          ON ads.EDW_FIN_DOC_ID = s.EDW_FIN_DOC_ID
    LEFT JOIN li_sum lis      ON lis.EDW_FIN_DOC_ID = s.EDW_FIN_DOC_ID
    LEFT JOIN pay_sum ps      ON ps.EDW_FIN_DOC_ID  = s.EDW_FIN_DOC_ID
    LEFT JOIN T_VEND v        ON v.EDW_PARTY_ID = iv.INV_VCHR_VEND_EDW_PARTY_ID
    LEFT JOIN T_POST_DOC invdoc ON invdoc.EDW_FIN_DOC_ID = iv.EDW_FIN_DOC_ID
    LEFT JOIN T_PO po         ON po.EDW_FIN_DOC_ID = iv.PO_EDW_FIN_DOC_ID
    LEFT JOIN T_POST_DOC podoc  ON podoc.EDW_FIN_DOC_ID = po.EDW_FIN_DOC_ID
    CROSS JOIN params prm
    WHERE ( prm.vend_id IS NULL OR v.VEND_ID = prm.vend_id )
)
SELECT *
FROM   rpt
/* TOGGLE: delete the next line to list ALL in-scope invoices with their
   status fields, not just the ones with issues. */
WHERE  ISSUE_LIST IS NOT NULL
ORDER BY
    UNPAID_AMT DESC,
    DAYS_SINCE_INV DESC
