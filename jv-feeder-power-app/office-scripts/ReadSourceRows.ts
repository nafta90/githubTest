/**
 * Run via Power Automate's "Run script" action against the file the user
 * uploads in the Canvas App.
 *
 * Reads the first worksheet's header row and data rows and returns them as
 * JSON so the flow can:
 *   1. Feed `headers` to the Canvas App's column-mapping screen.
 *   2. Pass the whole payload into PopulateFeederTemplate.ts once the user
 *      has mapped columns and set the AMOUNT/RULECODE options.
 */
function main(workbook: ExcelScript.Workbook): string {
  const sheet = workbook.getWorksheets()[0];
  const usedRange = sheet.getUsedRange();

  if (!usedRange) {
    return JSON.stringify({ headers: [], rows: [] });
  }

  const values = usedRange.getValues();
  const headers = values[0].map((h) => String(h ?? "").trim());

  const rows = values
    .slice(1)
    .filter((row) => row.some((cell) => cell !== "" && cell !== null))
    .map((row) => {
      const obj: Record<string, string | number | boolean> = {};
      headers.forEach((h, i) => {
        obj[h] = row[i];
      });
      return obj;
    });

  return JSON.stringify({ headers, rows });
}
