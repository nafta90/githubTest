/* =============================================================================
   VENDOR ACTIVITY REPORT
   =============================================================================
   Source      : Finance EDW (Banner Decision Support physical model)
   Platform    : Oracle (bind-variable parameters)
   Grain       : 1 row per Invoice Line Item x FOAP accounting distribution
                 (T_INV_VCHR_ACCTG_DETL). Payments are PRE-AGGREGATED to this
                 same grain, so rows never multiply from the payment join.

   Parameters: edit the PARAMS block at the top of the query (no bind
   variables -- works through ODBC / Power Query / Excel, which cannot bind
   Oracle :variables and raise ORA-01008 if any are present).
     start_dt  DATE      - include invoices with INV_VCHR_DT >= this date.
                           DEFAULT: rolling past 2 years
                           (ADD_MONTHS(TRUNC(SYSDATE), -24)).
                           Set to NULL for no lower bound (all history --
                           expect a much slower run).
     end_dt    DATE      - include invoices with INV_VCHR_DT <= this date
                           (implemented as < end_dt + 1 so a plain date
                           captures the whole day). NULL = no upper bound.
                           Example: DATE '2025-06-30'
     coll_cd   VARCHAR2  - college code filter on the Org hierarchy
                           (COLL_LEVEL_3_CD). Default 'FN' (Dentistry).
     vend_id   VARCHAR2  - optional single-vendor filter (T_VEND.VEND_ID).
                           NULL = all vendors.

   Notes / caveats:
     - Amount columns live at three levels: invoice line item, FOAP
       distribution (this report's grain), and payment. When summing, use the
       ACCTG_DETL_* amounts; line-item amounts repeat across their FOAP rows.
     - Cancelled invoices and cancelled checks are INCLUDED and flagged
       (INV_CNCL_IND, PAID_ANY_CHK_CNCL_IND) so cancellations remain visible;
       add "AND iv.INV_VCHR_CNCL_IND = 'N'" to exclude them.
     - "PO creator": the EDW model carries the PO requestor name/email
       (PO_RQSTR_NAME, PO_RQSTR_EMAIL_ADDR) and buyer code/name
       (PO_BYR_CD, PO_BYR_NAME); it has no creator net-ID/user-ID column.
     - User-facing document numbers (invoice doc #, PO #, check #) come from
       T_POST_DOC.POST_DOC_NBR keyed by the surrogate EDW_FIN_DOC_ID.
   ========================================================================== */

WITH params AS (
    /* ---- EDIT FILTERS HERE ------------------------------------------------
       Default date window = rolling past 2 years. Use fixed dates like
       CAST(DATE '2024-07-01' AS DATE), or NULL for no bound (all history). */
    SELECT
        ADD_MONTHS(TRUNC(SYSDATE), -24) AS start_dt,  -- past 2 years
        CAST(NULL AS DATE)          AS end_dt,     -- e.g. DATE '2025-06-30'
        'FN'                        AS coll_cd,    -- college code (Dentistry)
        CAST(NULL AS VARCHAR2(30))  AS vend_id     -- e.g. '123456789'
    FROM dual
),
pay AS (
    /* Payments rolled up to the invoice FOAP-distribution grain.
       One invoice distribution can be paid by multiple checks; aggregate so
       the main query stays 1:1. Check doc number comes from T_POST_DOC.
       Pre-filtered to invoices inside the report's date window so the
       aggregation never scans the whole check-detail table. */
    SELECT
        bcd.INV_VCHR_EDW_FIN_DOC_ID,
        bcd.INV_VCHR_LINE_ITEM_NBR,
        bcd.INV_VCHR_SEQ_NBR,
        COUNT(*)                                        AS CHK_COUNT,
        MIN(bc.BANK_CHK_DT)                             AS FIRST_CHK_DT,
        MAX(bc.BANK_CHK_DT)                             AS LAST_CHK_DT,
        SUM(bcd.BANK_CHK_INV_VCHR_GROSS_AMT)            AS PAID_GROSS_AMT,
        SUM(bcd.BANK_CHK_INV_VCHR_DISC_AMT)             AS PAID_DISC_AMT,
        SUM(bcd.BANK_CHK_INV_VCHR_ADDL_AMT)             AS PAID_ADDL_AMT,
        SUM(bcd.BANK_CHK_INV_VCHR_FED_WITH_AMT)         AS PAID_FED_WITH_AMT,
        SUM(bcd.BANK_CHK_INV_STATE_WITH_AMT)            AS PAID_STATE_WITH_AMT,
        LISTAGG(
            chkdoc.POST_DOC_NBR
            || CASE WHEN bc.BANK_CHK_ACH_IND  = 'Y' THEN ' (ACH)'  END
            || CASE WHEN bc.BANK_CHK_CNCL_IND = 'Y' THEN ' (CNCL)' END,
            '; '
        ) WITHIN GROUP (ORDER BY bc.BANK_CHK_DT)        AS CHK_NBR_LIST,
        MAX(CASE WHEN bc.BANK_CHK_ACH_IND  = 'Y' THEN 'Y' ELSE 'N' END)
                                                        AS PAID_ANY_ACH_IND,
        MAX(CASE WHEN bc.BANK_CHK_CNCL_IND = 'Y' THEN 'Y' ELSE 'N' END)
                                                        AS PAID_ANY_CHK_CNCL_IND
    FROM  T_BANK_CHK_INV_VCHR_DETL bcd
    JOIN  T_INV_VCHR pinv
          ON  pinv.EDW_FIN_DOC_ID = bcd.INV_VCHR_EDW_FIN_DOC_ID
    CROSS JOIN params prm
    JOIN  T_BANK_CHK bc
          ON  bc.EDW_FIN_DOC_ID  = bcd.BANK_CHECK_EDW_FIN_DOC_ID
          AND bc.BANK_CHK_BANK_CD = bcd.BANK_CHK_BANK_CD
    LEFT JOIN T_POST_DOC chkdoc
          ON  chkdoc.EDW_FIN_DOC_ID = bcd.BANK_CHECK_EDW_FIN_DOC_ID
    WHERE ( prm.start_dt IS NULL OR pinv.INV_VCHR_DT >= prm.start_dt )
      AND ( prm.end_dt   IS NULL OR pinv.INV_VCHR_DT <  prm.end_dt + 1 )
    GROUP BY
        bcd.INV_VCHR_EDW_FIN_DOC_ID,
        bcd.INV_VCHR_LINE_ITEM_NBR,
        bcd.INV_VCHR_SEQ_NBR
),
doc_txt AS (
    /* Free-form document text (item text) typed or interfaced onto the
       invoice. POST_DOC_LINE_ITEM_NBR ties text to a specific line; NULL
       means header-level text. Standard boilerplate clauses
       (POST_DOC_CLAUSE_NBR set) are excluded so only real descriptions
       remain. Pre-filtered to invoices in the report's date window.
       NOTE: ON OVERFLOW TRUNCATE needs Oracle 12.2+; on older versions
       remove that clause (very long text would then raise ORA-01489). */
    SELECT
        pdt.EDW_FIN_DOC_ID,
        pdt.POST_DOC_LINE_ITEM_NBR,
        LISTAGG(pdt.POST_DOC_TXT, ' ' ON OVERFLOW TRUNCATE)
            WITHIN GROUP (ORDER BY pdt.POST_DOC_TYPE_SEQ_NBR,
                                   pdt.POST_DOC_LINE_NBR)    AS DOC_TXT
    FROM  T_POST_DOC_TXT pdt
    JOIN  T_INV_VCHR tinv
          ON  tinv.EDW_FIN_DOC_ID = pdt.EDW_FIN_DOC_ID
    CROSS JOIN params prm
    WHERE pdt.POST_DOC_CLAUSE_NBR IS NULL
      AND ( prm.start_dt IS NULL OR tinv.INV_VCHR_DT >= prm.start_dt )
      AND ( prm.end_dt   IS NULL OR tinv.INV_VCHR_DT <  prm.end_dt + 1 )
    GROUP BY
        pdt.EDW_FIN_DOC_ID,
        pdt.POST_DOC_LINE_ITEM_NBR
)
SELECT
    /* ----------------------------- VENDOR ------------------------------- */
    v.VEND_ID,
    COALESCE(v.VEND_NAME, iv.INV_VCHR_VEND_NAME)        AS VEND_NAME,
    v.INCM_TYPE_CD                                      AS VEND_INCM_TYPE_CD,
    v.VEND_INSTATE_IND,
    v.VEND_BUS_STATE_CD,
    v.VEND_BUS_NATION_CD,
    v.VEND_CONTACT_PERS,
    v.VEND_CONTACT_AREA_CD || v.VEND_CONTACT_TELE_NBR   AS VEND_CONTACT_PHONE,
    iv.ONE_TIME_VEND_IND,
    iv.INV_VCHR_VEND_CITY                               AS INV_VEND_CITY,
    iv.INV_VCHR_VEND_STATE_CD                           AS INV_VEND_STATE_CD,

    /* ----------------------------- INVOICE ------------------------------ */
    invdoc.POST_DOC_NBR                                 AS INV_DOC_NBR,
    iv.VEND_INV_NBR,
    iv.INV_VCHR_DT,
    iv.INV_VCHR_TRAN_DT,
    iv.INV_VCHR_PMT_DUE_DT,
    iv.INV_VCHR_TYPE_IND,
    iv.CREDMEM_IND,
    iv.INV_VCHR_1099_IND,
    iv.INV_VCHR_HOLD_IND                                AS INV_HOLD_IND,
    iv.INV_VCHR_CNCL_IND                                AS INV_CNCL_IND,
    iv.INV_VCHR_CNCL_DT                                 AS INV_CNCL_DT,
    iv.INV_VCHR_OPEN_PD_IND                             AS INV_OPEN_PD_IND,
    iv.INV_VCHR_CREATE_SRC_DESC                         AS INV_CREATE_SRC_DESC,

    /* --------------------------- LINE ITEM ------------------------------ */
    li.INV_VCHR_LINE_ITEM_NBR,
    li.CMDTY_CD,
    li.INV_VCHR_LINE_ITEM_CMDTY_DESC                    AS LINE_ITEM_CMDTY_DESC,
    li.INV_VCHR_LINE_ITEM_UOM_CD                        AS LINE_ITEM_UOM_CD,
    li.INV_VCHR_LINE_ITEM_INV_QTY                       AS LINE_ITEM_INV_QTY,
    li.INV_VCHR_LINE_ITEM_INV_PRC                       AS LINE_ITEM_INV_PRC,
    li.INV_VCHR_LINE_ITEM_RCVD_QTY                      AS LINE_ITEM_RCVD_QTY,
    li.INV_VCHR_LINE_ITEM_ACPT_QTY                      AS LINE_ITEM_ACPT_QTY,
    li.INV_VCHR_LINE_ITEM_APRV_QTY                      AS LINE_ITEM_APRV_QTY,
    li.INV_VCHR_LINE_ITEM_TAX_AMT                       AS LINE_ITEM_TAX_AMT,
    li.INV_VCHR_LINE_ITEM_DISC_AMT                      AS LINE_ITEM_DISC_AMT,
    li.INV_VCHR_LINE_ITEM_ADDL_AMT                      AS LINE_ITEM_ADDL_AMT,
    li.INV_VCHR_LINE_ITEM_NET_AMT                       AS LINE_ITEM_NET_AMT,
    li.INV_VCHR_LINE_ITEM_RCV_STATUS                    AS LINE_ITEM_RCV_STATUS,
    litxt.DOC_TXT                                       AS LINE_ITEM_DOC_TEXT,
    hdrtxt.DOC_TXT                                      AS INV_HDR_DOC_TEXT,

    /* ------------------- FOAP ACCOUNTING DISTRIBUTION ------------------- */
    ad.INV_VCHR_SEQ_NBR                                 AS ACCTG_SEQ_NBR,
    ad.COA_CD,
    ad.FY_CD,
    ad.FISC_PERD_CD,
    ad.FIN_FUND_CD,
    fund.FIN_FUND_TITLE,
    ad.ORG_CD,
    org.ORG_TITLE,
    org.COLL_LEVEL_3_CD                                 AS COLLEGE_CD,
    org.COLL_LEVEL_3_TITLE                              AS COLLEGE_TITLE,
    org.DEPT_LEVEL_5_CD                                 AS DEPT_CD,
    org.DEPT_LEVEL_5_TITLE                              AS DEPT_TITLE,
    ad.FIN_ACCT_CD,
    acct.FIN_ACCT_TITLE,
    ad.FIN_PGM_CD,
    pgm.FIN_PGM_TITLE,
    ad.FIN_ACTV_CD,
    ad.LOCN_CD,
    ad.INV_VCHR_ACCTG_DETL_PD_IND                       AS ACCTG_DETL_PD_IND,
    ad.INV_VCHR_ACCTG_DETL_INV_AMT                      AS ACCTG_DETL_INV_AMT,
    ad.INV_VCHR_ACCTG_DETL_APRV_AMT                     AS ACCTG_DETL_APRV_AMT,
    ad.INV_VCHR_ACCTG_DETL_TAX_AMT                      AS ACCTG_DETL_TAX_AMT,
    ad.INV_VCHR_ACCTG_DETL_DISC_AMT                     AS ACCTG_DETL_DISC_AMT,
    ad.INV_VCHR_ACCTG_DETL_ADDL_AMT                     AS ACCTG_DETL_ADDL_AMT,
    ad.INV_VCHR_ACCTG_DETL_NET_AMT                      AS ACCTG_DETL_NET_AMT,

    /* ------------------------- PURCHASE ORDER --------------------------- */
    podoc.POST_DOC_NBR                                  AS PO_NBR,
    po.PO_ORD_DT,
    po.PO_DELIV_DT,
    po.PO_TYPE_IND,
    po.PO_CLS_DESC,
    po.PO_RQSTR_NAME,                                   -- PO creator/requestor
    po.PO_RQSTR_EMAIL_ADDR,                             -- PO creator/requestor email
    po.PO_BYR_CD,                                       -- buyer assigned to PO
    po.PO_BYR_NAME,
    po.PO_ATTN_NAME,
    po.ORG_CD                                           AS PO_ORG_CD,
    po.PO_CNCL_IND,
    po.PO_RCV_IND,
    po.BLANKET_ORD_EDW_ID,
    pli.PO_LINE_ITEM_NBR,
    pli.PO_LINE_ITEM_CMDTY_DESC,
    pli.PO_LINE_ITEM_QTY,
    pli.PO_LINE_ITEM_UNIT_PRC,
    pli.PO_LINE_ITEM_NET_AMT,
    pli.PO_LINE_ITEM_VEND_REF_NBR,

    /* ------------------------- PAYMENTS (CHECKS) ------------------------ */
    pay.CHK_COUNT,
    pay.CHK_NBR_LIST,
    pay.FIRST_CHK_DT,
    pay.LAST_CHK_DT,
    pay.PAID_GROSS_AMT,
    pay.PAID_DISC_AMT,
    pay.PAID_ADDL_AMT,
    pay.PAID_FED_WITH_AMT,
    pay.PAID_STATE_WITH_AMT,
    pay.PAID_ANY_ACH_IND,
    pay.PAID_ANY_CHK_CNCL_IND,
    CASE WHEN pay.INV_VCHR_EDW_FIN_DOC_ID IS NULL
         THEN 'UNPAID' ELSE 'PAID' END                  AS PAYMENT_STATUS

FROM  T_INV_VCHR iv
JOIN  T_INV_VCHR_LINE_ITEM li
      ON  li.EDW_FIN_DOC_ID = iv.EDW_FIN_DOC_ID
JOIN  T_INV_VCHR_ACCTG_DETL ad
      ON  ad.EDW_FIN_DOC_ID         = li.EDW_FIN_DOC_ID
      AND ad.INV_VCHR_LINE_ITEM_NBR = li.INV_VCHR_LINE_ITEM_NBR
LEFT JOIN T_VEND v
      ON  v.EDW_PARTY_ID = iv.INV_VCHR_VEND_EDW_PARTY_ID
LEFT JOIN T_POST_DOC invdoc
      ON  invdoc.EDW_FIN_DOC_ID = iv.EDW_FIN_DOC_ID
LEFT JOIN T_PO po
      ON  po.EDW_FIN_DOC_ID = iv.PO_EDW_FIN_DOC_ID
LEFT JOIN T_POST_DOC podoc
      ON  podoc.EDW_FIN_DOC_ID = po.EDW_FIN_DOC_ID
LEFT JOIN T_PO_LINE_ITEM pli
      ON  pli.EDW_FIN_DOC_ID   = li.PO_EDW_FIN_DOC_ID
      AND pli.PO_LINE_ITEM_NBR = li.PO_LINE_ITEM_NBR
/* Item text on this invoice line */
LEFT JOIN doc_txt litxt
      ON  litxt.EDW_FIN_DOC_ID         = li.EDW_FIN_DOC_ID
      AND litxt.POST_DOC_LINE_ITEM_NBR = li.INV_VCHR_LINE_ITEM_NBR
/* Header-level text on the invoice (common on one-line standing orders) */
LEFT JOIN doc_txt hdrtxt
      ON  hdrtxt.EDW_FIN_DOC_ID = iv.EDW_FIN_DOC_ID
      AND hdrtxt.POST_DOC_LINE_ITEM_NBR IS NULL
/* Org hierarchy: current-info row carries the college rollup (level 3). */
JOIN  T_ORG_CD_HIST org
      ON  org.COA_CD = ad.COA_CD
      AND org.ORG_CD = ad.ORG_CD
      AND org.ORG_CD_CUR_INFO_IND = 'Y'
LEFT JOIN T_FIN_FUND_CD_HIST fund
      ON  fund.COA_CD      = ad.COA_CD
      AND fund.FIN_FUND_CD = ad.FIN_FUND_CD
      AND fund.FIN_FUND_CD_CUR_INFO_IND = 'Y'
LEFT JOIN T_FIN_ACCT_CD_HIST acct
      ON  acct.COA_CD      = ad.COA_CD
      AND acct.FIN_ACCT_CD = ad.FIN_ACCT_CD
      AND acct.FIN_ACCT_CD_CUR_INFO_IND = 'Y'
LEFT JOIN T_FIN_PGM_CD_HIST pgm
      ON  pgm.COA_CD     = ad.COA_CD
      AND pgm.FIN_PGM_CD = ad.FIN_PGM_CD
      AND pgm.FIN_PGM_CD_CUR_INFO_IND = 'Y'
LEFT JOIN pay
      ON  pay.INV_VCHR_EDW_FIN_DOC_ID = ad.EDW_FIN_DOC_ID
      AND pay.INV_VCHR_LINE_ITEM_NBR  = ad.INV_VCHR_LINE_ITEM_NBR
      AND pay.INV_VCHR_SEQ_NBR        = ad.INV_VCHR_SEQ_NBR
CROSS JOIN params prm

WHERE 1 = 1
  /* College filter - set in the PARAMS block (default FN = Dentistry) */
  AND org.COLL_LEVEL_3_CD = NVL(prm.coll_cd, 'FN')
  /* Time-period filter - leave both NULL in PARAMS for all history */
  AND ( prm.start_dt IS NULL OR iv.INV_VCHR_DT >= prm.start_dt )
  AND ( prm.end_dt   IS NULL OR iv.INV_VCHR_DT <  prm.end_dt + 1 )
  /* Optional single-vendor filter */
  AND ( prm.vend_id  IS NULL OR v.VEND_ID = prm.vend_id )

/* No ORDER BY on purpose: sorting a large result server-side is expensive
   and Excel/Power BI re-sort locally anyway. Add one back if you need a
   deterministic order from SQL*Plus or a flat-file export. */
