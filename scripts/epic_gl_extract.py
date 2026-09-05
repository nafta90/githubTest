#!/usr/bin/env python3
"""
Extract Epic GL export text files into the acct-level / detail Excel
workbooks used to prepare the Banner journal feeder.

Inputs (fixed-width text files exported from Epic on a recurring basis):
  - fi_gl_transactions<Month>.txt  -> "acct-level extract" sheet
  - detailCODGL<Month>.txt         -> "detail extract" sheet

Both files use fixed character-column layouts (not whitespace-delimited),
so fields are sliced by column position rather than split on spaces.
Column positions were reverse-engineered from sample exports and verified
against the fi_gl_transactions trailer control record (record count and
total amount).

Usage:
    python epic_gl_extract.py \
        --gl fi_gl_transactionsJul.txt \
        --detail detailCODGLJul.txt \
        --output July_GL_extract.xlsx
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import openpyxl
from openpyxl.styles import Font
from openpyxl.utils import get_column_letter

FONT_NAME = "Arial"


# --------------------------------------------------------------------------
# fi_gl_transactions*.txt  ->  acct-level extract
# --------------------------------------------------------------------------

GL_COLUMNS = ["all", "rule", "date", "amt", "type", "dbOrCr", "bank", "fund", "org", "acct", "prog", "net"]


def _strip_leading_tab_index(raw_line: str) -> str:
    """Input lines are `<row number>\t<fixed-width body>`; return the body."""
    line = raw_line.rstrip("\n")
    tab_idx = line.find("\t")
    return line[tab_idx + 1:] if tab_idx != -1 else line


def parse_gl_file(path: Path) -> tuple[list[dict], dict]:
    """Parse fi_gl_transactions*.txt into acct-level extract rows.

    Returns (rows, control_totals) where control_totals holds the trailer
    record's reported row count / total amount for validation.
    """
    rows: list[dict] = []
    control = {"expected_count": None, "expected_total_cents": None}

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            body = _strip_leading_tab_index(raw_line)
            if not body.strip():
                continue

            record_type = body[16:17]

            if record_type == "1":
                # Header/run-date record - nothing needed for the extract.
                continue

            if record_type == "3":
                # Trailer control record: "<spaces>3<spaces><count><spaces><total_cents>"
                tail = body[17:].split()
                if len(tail) >= 2:
                    control["expected_count"] = int(tail[0])
                    control["expected_total_cents"] = int(tail[1])
                continue

            if record_type != "2":
                # Unrecognized record type - skip rather than mis-parse it.
                continue

            all_ = body[0:16].strip()
            rule = body[16:20].strip()
            date_str = body[21:27].strip()
            amt_cents = int(body[27:41].strip())
            type_ = body[41:47].strip()
            sign = body[76:77].strip()
            bank_code = body[77:79].strip()
            fund = body[86:92].strip()
            org = body[92:98].strip()
            acct = body[98:104].strip()
            prog = body[104:110].strip()

            net = amt_cents / 100.0
            if sign == "-":
                net = -net

            bank_value: object
            if bank_code:
                bank_value = f"{bank_code}2"
            else:
                bank_value = 2

            rows.append({
                "all": all_,
                "rule": int(rule) if rule else None,
                "date": int(date_str) if date_str else None,
                "amt": amt_cents,
                "type": type_,
                "dbOrCr": sign,
                "bank": bank_value,
                "fund": int(fund) if fund else None,
                "org": int(org) if org else None,
                "acct": int(acct) if acct else None,
                "prog": int(prog) if prog else None,
                "net": round(net, 2),
            })

    return rows, control


# --------------------------------------------------------------------------
# detailCODGL*.txt  ->  detail extract
# --------------------------------------------------------------------------

DETAIL_COLUMNS = [
    "activity group", "transaction type", "transaction id", "pb matched transaction id",
    "fund", "org", "acct", "prog", "trans type", "bank", "rule code",
    "bill area", "bill area calculated", "amt", "activity date", "from date", "to date",
    "procedure", "orig financial class", "guarantor",
    "fin division", "pb credit fin division calculated",
    "fin subdivision", "pb credit fin subdivision calculated",
    "department", "orig payer", "etr bill area",
]

_DATE_FMT = "%m/%d/%Y"


def _parse_date(s: str):
    s = s.strip()
    if not s:
        return None
    try:
        return datetime.strptime(s, _DATE_FMT).date()
    except ValueError:
        return s


def _int_or_none(s: str):
    s = s.strip()
    return int(s) if s else None


def _num_or_str(s: str):
    s = s.strip()
    if not s:
        return None
    return int(s) if s.isdigit() else s


def parse_detail_file(path: Path) -> list[dict]:
    rows: list[dict] = []

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            body = _strip_leading_tab_index(raw_line)
            if not body.strip():
                continue
            if len(body) < 236:
                # Not a data row (too short to hold the fixed fields).
                continue

            trans_id_str = body[20:28].strip()
            amt_str = body[222:236].strip()
            if not trans_id_str.isdigit() or not amt_str:
                continue

            rows.append({
                "activity group": body[0:10].strip(),
                "transaction type": body[10:20].strip(),
                "transaction id": int(trans_id_str),
                "pb matched transaction id": body[28:42].strip() or None,
                "fund": _int_or_none(body[42:48]),
                "org": _int_or_none(body[48:54]),
                "acct": _int_or_none(body[54:60]),
                "prog": _int_or_none(body[60:66]),
                "trans type": body[67:73].strip(),
                "bank": body[74:76].strip() or None,
                "rule code": _int_or_none(body[77:80]),
                "bill area": body[80:162].strip() or None,
                "bill area calculated": body[162:222].strip() or None,
                "amt": float(amt_str),
                "activity date": _parse_date(body[236:246]),
                "from date": _parse_date(body[250:260]),
                "to date": _parse_date(body[264:274]),
                "procedure": _num_or_str(body[278:289]),
                "orig financial class": body[289:390].strip() or None,
                "guarantor": body[390:490].strip() or None,
                "fin division": body[490:535].strip() or None,
                "pb credit fin division calculated": body[535:572].strip() or None,
                "fin subdivision": body[572:622].strip() or None,
                "pb credit fin subdivision calculated": body[622:672].strip() or None,
                "department": body[672:716].strip() or None,
                "orig payer": body[716:800].strip() or None,
                "etr bill area": None,
            })

    return rows


# --------------------------------------------------------------------------
# Workbook output
# --------------------------------------------------------------------------

def _write_sheet(wb: openpyxl.Workbook, title: str, columns: list[str], rows: list[dict], date_cols: set[str]) -> None:
    ws = wb.create_sheet(title=title)
    ws.append(columns)
    for cell in ws[1]:
        cell.font = Font(name=FONT_NAME, bold=True)

    for row in rows:
        ws.append([row.get(col) for col in columns])

    for row_cells in ws.iter_rows(min_row=2, max_row=ws.max_row):
        for cell, col in zip(row_cells, columns):
            cell.font = Font(name=FONT_NAME)
            if col in date_cols and cell.value is not None:
                cell.number_format = "mm/dd/yyyy"
            elif col in ("amt", "net") and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.00;(#,##0.00)"

    for i, col in enumerate(columns, start=1):
        width = max(len(col) + 2, 12)
        ws.column_dimensions[get_column_letter(i)].width = min(width, 40)

    ws.freeze_panes = "A2"


def write_workbook(gl_rows: list[dict] | None, detail_rows: list[dict] | None, output_path: Path) -> None:
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    if gl_rows is not None:
        _write_sheet(wb, "acct-level extract", GL_COLUMNS, gl_rows, date_cols=set())
    if detail_rows is not None:
        _write_sheet(wb, "detail extract", DETAIL_COLUMNS, detail_rows,
                     date_cols={"activity date", "from date", "to date"})
    wb.save(output_path)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gl", type=Path, help="Path to fi_gl_transactions<Month>.txt")
    parser.add_argument("--detail", type=Path, help="Path to detailCODGL<Month>.txt")
    parser.add_argument("--output", required=True, type=Path, help="Path to write the output .xlsx")
    args = parser.parse_args(argv)

    if args.gl is None and args.detail is None:
        parser.error("provide at least one of --gl or --detail")

    gl_rows = None
    if args.gl is not None:
        gl_rows, control = parse_gl_file(args.gl)
        print(f"Parsed {len(gl_rows)} acct-level rows from {args.gl.name}")

        if control["expected_count"] is not None:
            if control["expected_count"] != len(gl_rows):
                print(
                    f"WARNING: trailer record reports {control['expected_count']} rows, "
                    f"parsed {len(gl_rows)}. Check the fixed-width column positions in "
                    f"parse_gl_file() against this file's layout.",
                    file=sys.stderr,
                )
            actual_total_cents = sum(row["amt"] for row in gl_rows)
            if control["expected_total_cents"] != actual_total_cents:
                print(
                    f"WARNING: trailer record reports total {control['expected_total_cents']} cents, "
                    f"parsed total {actual_total_cents} cents.",
                    file=sys.stderr,
                )
            else:
                print("Control totals OK: row count and amount total match the trailer record.")

    detail_rows = None
    if args.detail is not None:
        detail_rows = parse_detail_file(args.detail)
        print(f"Parsed {len(detail_rows)} detail rows from {args.detail.name}")

    write_workbook(gl_rows, detail_rows, args.output)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
