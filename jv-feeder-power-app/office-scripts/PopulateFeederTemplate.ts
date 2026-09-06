/**
 * Run via Power Automate's "Run script" action against a fresh COPY of the
 * blank JV Feeder Template (create the copy with a SharePoint "Copy file"
 * action earlier in the flow — this script never touches the original
 * template).
 *
 * Port of populate_jv_feeder.py's map_row()/write_feeder(), generalized so
 * the column mapping and the two source-system-specific transforms come in
 * as parameters instead of being hardcoded to the Epic extract's layout.
 *
 * Parameters (all passed by the flow as JSON strings):
 *   sourceDataJson   - output of ReadSourceRows.ts: { headers, rows }
 *   columnMappingJson - Record<FeederColumn, sourceHeader | null>, e.g.
 *       { "RULECODE": "Rule Code", "AMOUNT": "Amount", "BANKCODE": "Bank", ... }
 *   optionsJson      - { amountDivideBy100: boolean, ruleCodeStripPrefix: boolean }
 *       Both default to false — most uploaded .xlsx/.csv files already have
 *       dollar amounts and plain rule codes. Turn these on only for
 *       Epic-style extracts (cents-as-integer amounts, chart-prefixed rule
 *       codes).
 */

const COA_VALUE = 2;

// Feeder columns this feed never populates from user data.
const UNUSED_FEEDER_COLUMNS = [
  "ACTIVITY",
  "LOCATION",
  "ENCDNUM",
  "ENCDITEMNUM",
  "ENCDSEQNUM",
  "ENCDACTIONIND",
  "ENCBTYPE",
];

interface MappingOptions {
  amountDivideBy100: boolean;
  ruleCodeStripPrefix: boolean;
}

type CellValue = string | number | boolean;
type SourceRow = Record<string, CellValue>;

/** Epic-specific: chart-prefixed rule code, e.g. "2125" -> "125". Optional. */
function stripRuleCodePrefix(value: CellValue | undefined): CellValue | null {
  if (value === undefined || value === null || value === "") return null;
  const s = String(value).trim();
  const last3 = s.slice(-3);
  return /^\d+$/.test(last3) ? Number(last3) : last3;
}

/** Always applied: Banner bank codes never carry the trailing COA digit. */
function stripBankCodeSuffix(value: CellValue | undefined): CellValue | null {
  if (value === undefined || value === null || value === "") return null;
  let s = String(value).trim();
  if (s.endsWith("2")) s = s.slice(0, -1);
  return s === "" ? null : s;
}

/** Epic-specific: cents-as-integer amounts. Optional. */
function toAmount(value: CellValue | undefined, divideBy100: boolean): number | null {
  if (value === undefined || value === null || value === "") return null;
  const n = Number(value);
  if (Number.isNaN(n)) return null;
  const dollars = divideBy100 ? n / 100 : n;
  return Math.round(dollars * 100) / 100;
}

function mapRow(
  sourceRow: SourceRow,
  mapping: Record<string, string | null>,
  options: MappingOptions
): Record<string, CellValue | null> {
  const fromSource = (feederCol: string): CellValue | undefined => {
    const sourceHeader = mapping[feederCol];
    if (!sourceHeader) return undefined;
    return sourceRow[sourceHeader];
  };

  const result: Record<string, CellValue | null> = {
    RULECODE: options.ruleCodeStripPrefix
      ? stripRuleCodePrefix(fromSource("RULECODE"))
      : fromSource("RULECODE") ?? null,
    DOCREFERENCENUMBER: fromSource("DOCREFERENCENUMBER") ?? null,
    AMOUNT: toAmount(fromSource("AMOUNT"), options.amountDivideBy100),
    DESCRIPTION: fromSource("DESCRIPTION") ?? null,
    "SIGN (+/-)": fromSource("SIGN (+/-)") ?? null,
    BANKCODE: stripBankCodeSuffix(fromSource("BANKCODE")),
    COA: COA_VALUE,
    FUND: fromSource("FUND") ?? null,
    ORG: fromSource("ORG") ?? null,
    ACCOUNT: fromSource("ACCOUNT") ?? null,
    PROGRAM: fromSource("PROGRAM") ?? null,
  };

  for (const col of UNUSED_FEEDER_COLUMNS) {
    result[col] = null;
  }

  return result;
}

function main(
  workbook: ExcelScript.Workbook,
  sourceDataJson: string,
  columnMappingJson: string,
  optionsJson: string
): number {
  const { rows } = JSON.parse(sourceDataJson) as { headers: string[]; rows: SourceRow[] };
  const mapping = JSON.parse(columnMappingJson) as Record<string, string | null>;
  const options = JSON.parse(optionsJson) as MappingOptions;

  const sheet = workbook.getWorksheets()[0];
  const usedRange = sheet.getUsedRange();
  if (!usedRange) {
    throw new Error("Template sheet has no header row.");
  }

  const feederHeader = usedRange.getValues()[0].map((h) => String(h ?? "").trim());
  const feederRows = rows.map((r) => mapRow(r, mapping, options));

  const outputValues: CellValue[][] = feederRows.map((row) =>
    feederHeader.map((col) => {
      const v = row[col];
      return v === undefined || v === null ? "" : v;
    })
  );

  if (outputValues.length === 0) return 0;

  // Template ships with just the header row, so the next empty row index
  // equals the current used-range row count.
  const startRow = usedRange.getRowCount();
  const targetRange = sheet.getRangeByIndexes(startRow, 0, outputValues.length, feederHeader.length);
  targetRange.setValues(outputValues);

  return outputValues.length;
}
