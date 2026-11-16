// =============================================================================
// iBuy <-> EDW RECONCILIATION - Power Query (M) code
// =============================================================================
// HOW TO INSTALL (Excel: Data > Get Data > Launch Power Query Editor;
// Power BI: Home > Transform data):
//
//   0. Prerequisite: you already have a query that runs
//      sql/vendor_activity_report.sql over ODBC. RENAME that query to
//      "EDW_Invoices" (right-click it > Rename). Nothing else about it
//      needs to change.
//   1. New Source > Blank Query, open Advanced Editor, delete what's there,
//      paste SECTION 1, click Done, rename the query "IbuyCsvPath".
//      Edit the path to where your iBuy export lives.
//   2. Repeat for SECTION 2 -> rename "iBuy_Lines".
//   3. Repeat for SECTION 3 -> rename "iBuy_ByInvoice".
//   4. Repeat for SECTION 4 -> rename "Reconciliation". This is the result:
//      Close & Load it to a worksheet/model; the helper queries can be
//      loaded as "Connection only".
//
// Query names matter - the sections reference each other by name.
// =============================================================================


// ---------------------------------------------------------------------------
// SECTION 1 - paste into a blank query named: IbuyCsvPath
// ---------------------------------------------------------------------------
"C:\Users\you\Downloads\transaction_export_buyer_invoice_search.csv"
// meta [IsParameterQuery = true]


// ---------------------------------------------------------------------------
// SECTION 2 - paste into a blank query named: iBuy_Lines
// One row per iBuy invoice line; duplicate line splits are summed so a
// line-level merge never fans out. Encoding 1252 = the export's real encoding.
// ---------------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(IbuyCsvPath),
                 [Delimiter = ",", Encoding = 1252, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Typed    = Table.TransformColumnTypes(Promoted, {
                 {"PO Line No",                  Int64.Type},
                 {"Quantity",                    type number},
                 {"Invoice Line Unit Price",     type number},
                 {"Invoice Line Extended Price", type number},
                 {"Invoice Total",               type number},
                 {"Invoice Date",                type date},
                 {"Paid Date",                   type date}
               }, "en-US"),
    AddInvKey = Table.AddColumn(Typed, "INV_KEY",
                 each Text.Upper(Text.Trim([Supplier Invoice No])), type text),
    AddPoKey  = Table.AddColumn(AddInvKey, "PO_KEY",
                 each Text.Upper(Text.Trim([PO No])), type text),
    // Collapse duplicate (invoice, PO line) rows (qty splits) into one row
    Grouped  = Table.Group(AddPoKey, {"INV_KEY", "PO_KEY", "PO Line No"}, {
                 {"iBuy Product",     each Text.Combine(List.Distinct(List.RemoveNulls([Product Name])), "; "), type text},
                 {"iBuy Catalog No",  each Text.Combine(List.Distinct(List.RemoveNulls([Catalog No])), "; "),   type text},
                 {"iBuy UOM",         each Text.Combine(List.Distinct(List.RemoveNulls([UOM])), "; "),          type text},
                 {"iBuy Qty",         each List.Sum([Quantity]),                     type number},
                 {"iBuy Unit Price",  each List.Max([Invoice Line Unit Price]),      type number},
                 {"iBuy Ext Price",   each List.Sum([Invoice Line Extended Price]),  type number},
                 {"iBuy Invoice Status", each List.First([Invoice Status]),          type text},
                 {"iBuy Paid Date",   each List.Max([Paid Date]),                    type date},
                 {"iBuy Invoice Total", each List.First([Invoice Total]),            type number},
                 {"iBuy Invoice Date",  each List.First([Invoice Date]),             type date}
               })
in
    Grouped


// ---------------------------------------------------------------------------
// SECTION 3 - paste into a blank query named: iBuy_ByInvoice
// One row per iBuy invoice: all product names combined + line totals.
// Used for standing orders, where many iBuy lines = one Banner line.
// ---------------------------------------------------------------------------
let
    Source  = iBuy_Lines,
    Grouped = Table.Group(Source, {"INV_KEY"}, {
                {"iBuy All Products",  each Text.Combine(List.Distinct(List.RemoveNulls([iBuy Product])), "; "), type text},
                {"iBuy Line Count",    each Table.RowCount(_),              Int64.Type},
                {"iBuy Lines Total",   each List.Sum([iBuy Ext Price]),     type number},
                {"iBuy Invoice Total", each List.First([iBuy Invoice Total]), type number},
                {"iBuy Invoice Status", each List.First([iBuy Invoice Status]), type text}
              }),
    // Header-level charges (tax/shipping/handling) show up as this variance
    AddHdr  = Table.AddColumn(Grouped, "iBuy Header Charges",
                each Number.Round([iBuy Invoice Total] - [iBuy Lines Total], 2),
                type number)
in
    AddHdr


// ---------------------------------------------------------------------------
// SECTION 4 - paste into a blank query named: Reconciliation
// EDW detail rows + iBuy descriptions. Line-level match first; invoice-level
// fallback covers standing orders. MATCH_STATUS tells you which happened.
// ---------------------------------------------------------------------------
let
    Source     = EDW_Invoices,
    AddInvKey  = Table.AddColumn(Source, "INV_KEY",
                   each Text.Upper(Text.Trim(Text.From([VEND_INV_NBR]))), type text),

    // --- 1) line-level merge (regular POs): invoice no + PO line no ---
    JoinLine   = Table.NestedJoin(AddInvKey,
                   {"INV_KEY", "PO_LINE_ITEM_NBR"},
                   iBuy_Lines,
                   {"INV_KEY", "PO Line No"},
                   "ibuyL", JoinKind.LeftOuter),
    ExpandLine = Table.ExpandTableColumn(JoinLine, "ibuyL",
                   {"iBuy Product", "iBuy Catalog No", "iBuy UOM",
                    "iBuy Qty", "iBuy Unit Price", "iBuy Ext Price"},
                   {"iBuy Product (Line)", "iBuy Catalog No", "iBuy UOM",
                    "iBuy Qty", "iBuy Unit Price", "iBuy Ext Price"}),

    // --- 2) invoice-level merge (standing orders / fallback) ---
    JoinInv    = Table.NestedJoin(ExpandLine, {"INV_KEY"},
                   iBuy_ByInvoice, {"INV_KEY"},
                   "ibuyI", JoinKind.LeftOuter),
    ExpandInv  = Table.ExpandTableColumn(JoinInv, "ibuyI",
                   {"iBuy All Products", "iBuy Line Count", "iBuy Lines Total",
                    "iBuy Invoice Total", "iBuy Header Charges",
                    "iBuy Invoice Status"},
                   {"iBuy All Products", "iBuy Line Count", "iBuy Lines Total",
                    "iBuy Invoice Total", "iBuy Header Charges",
                    "iBuy Invoice Status"}),

    // --- 3) best available description + how the match was made ---
    AddDesc    = Table.AddColumn(ExpandInv, "iBuy Description",
                   each if [#"iBuy Product (Line)"] <> null
                        then [#"iBuy Product (Line)"]
                        else [iBuy All Products], type text),
    AddStatus  = Table.AddColumn(AddDesc, "MATCH_STATUS",
                   each if [#"iBuy Product (Line)"] <> null then "LINE MATCH"
                        else if [iBuy All Products] <> null then "INVOICE MATCH ONLY"
                        else "NO IBUY MATCH", type text),

    // --- 4) tie-out. CAUTION: EDW grain is line x FOAP distribution, so on
    //        FOAP-split lines this variance repeats per row - judge it only
    //        where ACCTG_SEQ_NBR is the line's first/only distribution,
    //        or compare ACCTG_DETL_NET_AMT summed per line instead. ---
    AddVar     = Table.AddColumn(AddStatus, "Line Amt Variance (EDW-iBuy)",
                   each if [iBuy Ext Price] = null then null
                        else Number.Round([LINE_ITEM_NET_AMT] - [iBuy Ext Price], 2),
                   type number)
in
    AddVar
