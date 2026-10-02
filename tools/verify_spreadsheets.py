#!/usr/bin/env python3
"""Recalculate every shipped spreadsheet in LibreOffice and check the results.

Fails on any formula error and on wrong totals in the example files.
Requires `soffice` on PATH.   python3 tools/verify_spreadsheets.py
"""
import csv
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERRORS = ("#NAME?", "#VALUE!", "#REF!", "#DIV/0!", "#N/A", "#NUM!", "Err:")
CSV_FILTER = "csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,-1"
failures = []


def check(label, got, want, tol=0.005):
    if abs(got - want) > tol:
        failures.append(f"{label}: got {got}, want {want}")


def export(xlsx, outdir):
    subprocess.run(["soffice", "--headless", "--convert-to", CSV_FILTER, "--outdir", str(outdir), str(xlsx)],
                   check=True, capture_output=True, timeout=180)
    sheets = {}
    for f in outdir.glob(f"{xlsx.stem}-*.csv"):
        sheets[f.stem[len(xlsx.stem) + 1:]] = list(csv.reader(f.open(encoding="utf-8")))
    return sheets


def num(rows, r, c):
    return float(rows[r - 1][c - 1].replace(",", ""))  # 1-based, like the sheet


def find(rows, label):
    for row in rows:
        for i, cell in enumerate(row):
            if cell == label:
                return row, i
    raise KeyError(label)


def verify(xlsx):
    with tempfile.TemporaryDirectory() as tmp:
        sheets = export(xlsx, Path(tmp))
    if not sheets:
        failures.append(f"{xlsx.name}: no sheets exported")
        return
    for name, rows in sheets.items():
        for r, row in enumerate(rows, start=1):
            for cell in row:
                if any(e in cell for e in ERRORS):
                    failures.append(f"{xlsx.name}/{name} row {r}: {cell}")
    if not xlsx.stem.endswith("example"):
        return
    n = xlsx.name
    if n.startswith("freelancer"):
        status = [row[7] for row in sheets["Invoices"][1:7]]
        if status != ["Paid", "Paid", "Overdue", "Sent", "Sent", ""]:
            failures.append(f"{n}: invoice statuses {status}")
        summary = sheets["Summary"]
        row, i = find(summary, "Total outstanding")
        check(f"{n} outstanding", float(row[i + 1].replace(",", "")), 4600)
        row, i = find(summary, "Overdue")
        check(f"{n} overdue", float(row[i + 1].replace(",", "")), 2400)
        if date.today().timetuple().tm_yday > 80:  # sample dates reach back 75 days
            row, _ = find(summary, "Year total")
            vals = [float(x.replace(",", "")) for x in row[1:5]]
            check(f"{n} income", vals[0], 2750)
            check(f"{n} expenses", vals[1], 1570.39)
            check(f"{n} profit", vals[2], 1179.61)
            check(f"{n} set-aside", vals[3], 294.9025)
    if n.startswith("subscription"):
        dash = sheets["Dashboard"]
        for label, want in (("Active subscriptions", 6), ("Total per month", 138.8025),
                            ("Total per year", 1665.63), ("Renewing in the next 30 days (count)", 4),
                            ("Renewing in the next 30 days (amount)", 122.47),
                            ("Potential yearly savings", 623.88)):
            row, i = find(dash, label)
            check(f"{n} {label}", float(row[i + 1].replace(",", "")), want)
        flags = [row[10] for row in sheets["Subscriptions"][1:8]]
        want = ["Renews soon", "", "Low use - review", "Cancelling", "Update renewal date", "", ""]
        if flags != want:
            failures.append(f"{n}: flags {flags}, want {want}")


def main():
    files = sorted(ROOT.glob("products/*/files/*.xlsx"))
    if not files:
        sys.exit("no spreadsheets found")
    for f in files:
        verify(f)
        print("checked", f.relative_to(ROOT))
    if failures:
        print("\nFAILED:")
        print("\n".join(f"  {x}" for x in failures))
        sys.exit(1)
    print("all spreadsheets OK")


if __name__ == "__main__":
    main()
