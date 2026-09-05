#!/usr/bin/env python3
"""
Watch an inbox folder for a matching pair of Epic GL export text files,
and when both are present, run the full pipeline automatically:

    fi_gl_transactions<Period>.txt  \
    detailCODGL<Period>.txt          -->  epic_gl_extract.py  -->  <Period>_GL_extract.xlsx
                                      -->  populate_jv_feeder.py --> <Period>_JV_Feeder.xlsx

Designed to be run periodically (e.g. every 15 minutes via Windows Task
Scheduler) rather than as an always-on background process: each run scans
the inbox once, processes any complete, stable pairs it finds, and exits.
Running it again when nothing new has arrived is a fast no-op.

A "period" is whatever follows the fixed prefix in each filename, e.g. "Jul"
in "fi_gl_transactionsJul.txt" and "detailCODGLJul.txt" - the two files are
paired up by matching that suffix (case-insensitive).

Safety behavior:
  - A file is only processed once its size is stable across a short pause,
    so a file still being copied onto a network/cloud drive is skipped and
    retried on the next run instead of being read mid-copy.
  - On success, both source files are moved into an "processed" subfolder
    of the inbox, timestamped, so they are never picked up and reprocessed.
  - Every run appends a line to a log file recording what it did (or that
    it found nothing to do), so a scheduled run's history is auditable.

Usage:
    python watch_and_process.py \
        --inbox "I:\\Fiscal Affairs\\FINANCE- Alex A\\Epic\\GL Test" \
        --output "I:\\Fiscal Affairs\\FINANCE- Alex A\\Epic\\GL Output" \
        --template templates\\JVFeederTemplate.xlsx
"""
from __future__ import annotations

import argparse
import logging
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from epic_gl_extract import parse_gl_file, parse_detail_file, write_workbook  # noqa: E402
from populate_jv_feeder import read_extract_rows, map_row, write_feeder  # noqa: E402

GL_PATTERN = re.compile(r"^fi_gl_transactions(.+)\.txt$", re.IGNORECASE)
DETAIL_PATTERN = re.compile(r"^detailCODGL(.+)\.txt$", re.IGNORECASE)

STABILITY_CHECK_SECONDS = 3

logger = logging.getLogger("watch_and_process")


def _is_stable(path: Path) -> bool:
    """True if the file's size doesn't change across a short pause - i.e. it's
    not still being written or copied onto this folder."""
    size_before = path.stat().st_size
    time.sleep(STABILITY_CHECK_SECONDS)
    size_after = path.stat().st_size
    return size_before == size_after


def find_pending_pairs(inbox: Path) -> dict[str, dict[str, Path]]:
    """Group files in the inbox by period key, e.g. {"Jul": {"gl": Path(...), "detail": Path(...)}}."""
    pairs: dict[str, dict[str, Path]] = {}
    for f in inbox.iterdir():
        if not f.is_file():
            continue
        if m := GL_PATTERN.match(f.name):
            pairs.setdefault(m.group(1), {})["gl"] = f
        elif m := DETAIL_PATTERN.match(f.name):
            pairs.setdefault(m.group(1), {})["detail"] = f
    return {period: files for period, files in pairs.items() if "gl" in files and "detail" in files}


def process_period(period: str, gl_path: Path, detail_path: Path, output_dir: Path, template_path: Path) -> bool:
    """Run the extract + feeder pipeline for one period. Returns True on success."""
    logger.info("Processing period '%s': %s, %s", period, gl_path.name, detail_path.name)

    gl_rows, control = parse_gl_file(gl_path)
    detail_rows = parse_detail_file(detail_path)
    logger.info("Parsed %d acct-level rows, %d detail rows", len(gl_rows), len(detail_rows))

    if control["expected_count"] is not None:
        actual_total_cents = sum(row["amt"] for row in gl_rows)
        if control["expected_count"] != len(gl_rows) or control["expected_total_cents"] != actual_total_cents:
            logger.warning(
                "Control-total mismatch for period '%s': trailer expects %s rows / %s cents, "
                "parsed %d rows / %d cents. Check whether Epic changed the export layout.",
                period, control["expected_count"], control["expected_total_cents"],
                len(gl_rows), actual_total_cents,
            )
        else:
            logger.info("Control totals OK for period '%s'.", period)

    extract_path = output_dir / f"{period}_GL_extract.xlsx"
    write_workbook(gl_rows, detail_rows, extract_path)
    logger.info("Wrote %s", extract_path)

    extract_rows = read_extract_rows(extract_path)
    feeder_rows = [map_row(r) for r in extract_rows]
    feeder_path = output_dir / f"{period}_JV_Feeder.xlsx"
    write_feeder(feeder_rows, template_path, feeder_path)
    logger.info("Wrote %s (%d rows)", feeder_path, len(feeder_rows))

    return True


def archive_source_files(gl_path: Path, detail_path: Path, inbox: Path) -> None:
    processed_dir = inbox / "processed"
    processed_dir.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    for src in (gl_path, detail_path):
        dest = processed_dir / f"{stamp}_{src.name}"
        shutil.move(str(src), str(dest))
        logger.info("Archived %s -> %s", src.name, dest)


def run_once(inbox: Path, output_dir: Path, template_path: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    pairs = find_pending_pairs(inbox)

    if not pairs:
        logger.info("No complete file pairs found in %s.", inbox)
        return

    for period, files in pairs.items():
        gl_path, detail_path = files["gl"], files["detail"]

        if not (_is_stable(gl_path) and _is_stable(detail_path)):
            logger.info("Period '%s' files still changing size - will retry next run.", period)
            continue

        try:
            process_period(period, gl_path, detail_path, output_dir, template_path)
            archive_source_files(gl_path, detail_path, inbox)
        except Exception:
            logger.exception("Failed to process period '%s' (%s, %s) - left in place for the next run.",
                              period, gl_path.name, detail_path.name)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--inbox", required=True, type=Path, help="Folder to watch for Epic export .txt files")
    parser.add_argument("--output", required=True, type=Path, help="Folder to write the extract and feeder .xlsx files")
    parser.add_argument("--template", required=True, type=Path, help="Path to the blank JV Feeder Template .xlsx")
    parser.add_argument("--log", type=Path, default=None,
                         help="Path to a log file to append to (default: <output>/watch_and_process.log)")
    args = parser.parse_args(argv)

    log_path = args.log or (args.output / "watch_and_process.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(log_path, encoding="utf-8"), logging.StreamHandler()],
    )

    run_once(args.inbox, args.output, args.template)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
