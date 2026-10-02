#!/usr/bin/env python3
"""Generate the spreadsheet products.

The .xlsx files under products/*/files/ are committed, so the storefront build
needs only Node. Re-run this script after changing a template:

    pip install -r tools/requirements.txt
    python3 tools/make_spreadsheets.py
"""
from pathlib import Path

from openpyxl import Workbook
from openpyxl.chart import BarChart, Reference
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

ROOT = Path(__file__).resolve().parent.parent
ROWS = 500  # data rows pre-wired with formulas

HEADER_FILL = PatternFill("solid", fgColor="1F4E5F")
INPUT_FILL = PatternFill("solid", fgColor="EAF3FB")
CALC_FILL = PatternFill("solid", fgColor="F4F4F4")
GOOD_FILL = PatternFill("solid", fgColor="D9F2E0")
BAD_FILL = PatternFill("solid", fgColor="F9D6D5")
WARN_FILL = PatternFill("solid", fgColor="FDEBC8")
THIN = Side(style="thin", color="D0D7DE")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
MONEY = "#,##0.00"
DATE = "yyyy-mm-dd"


def title(ws, text, subtitle=None):
    ws["A1"] = text
    ws["A1"].font = Font(size=16, bold=True, color="1F4E5F")
    if subtitle:
        ws["A2"] = subtitle
        ws["A2"].font = Font(italic=True, color="666666")


def header(ws, row, labels, widths):
    for i, (label, width) in enumerate(zip(labels, widths), start=1):
        cell = ws.cell(row=row, column=i, value=label)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = HEADER_FILL
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        ws.column_dimensions[get_column_letter(i)].width = width
    ws.row_dimensions[row].height = 30


def paint(ws, cols, first, last, fill, fmt=None):
    """Fill a block of cells; `cols` is a string of column letters."""
    for col in cols:
        for r in range(first, last + 1):
            c = ws[f"{col}{r}"]
            c.fill = fill
            c.border = BOX
            if fmt:
                c.number_format = fmt


def finish(wb, list_sheets=()):
    """Print setup: landscape, one page wide. List sheets print their first 60 rows only,
    otherwise every pre-formatted blank row would print."""
    for ws in wb.worksheets:
        ws.page_setup.orientation = "landscape"
        ws.page_setup.fitToWidth = 1
        ws.page_setup.fitToHeight = 0
        ws.sheet_properties.pageSetUpPr.fitToPage = True
        if ws.title in list_sheets:
            ws.print_area = f"A1:{get_column_letter(ws.max_column)}60"
    wb.calculation.fullCalcOnLoad = True


def start_here(wb, heading, lines):
    ws = wb.active
    ws.title = "Start Here"
    title(ws, heading)
    ws.column_dimensions["A"].width = 110
    for i, line in enumerate(lines, start=3):
        c = ws.cell(row=i, column=1, value=line)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        if line and not line.startswith(("  ", "-")) and line.endswith(":"):
            c.font = Font(bold=True)
    key = len(lines) + 4
    ws.cell(row=key, column=1, value="Colour key").font = Font(bold=True)
    ws.cell(row=key + 1, column=1, value="Blue cells are for you to fill in.").fill = INPUT_FILL
    ws.cell(row=key + 2, column=1, value="Grey cells are formulas. Leave them alone.").fill = CALC_FILL
    return ws


# --------------------------------------------------------------------------
# Freelancer Money Tracker
# --------------------------------------------------------------------------
CATEGORIES = [
    "Software & subscriptions", "Equipment", "Home office", "Travel",
    "Marketing", "Professional fees", "Education", "Bank & payment fees",
    "Other", "Custom 1", "Custom 2",
]


def freelancer_tracker(with_sample):
    wb = Workbook()
    start_here(wb, "Freelancer Money Tracker", [
        "What this does:",
        "Log invoices and expenses. The Summary sheet shows income, expenses, profit and a suggested tax set-aside for every month, "
        "and the Invoices sheet flags who is overdue.",
        "",
        "Set up (2 minutes):",
        "1. Open the Settings sheet and set your tax set-aside rate and default payment terms.",
        "2. Add one row per invoice on the Invoices sheet. Fill in the blue cells only. Due date, status and days overdue fill themselves in.",
        "3. When a client pays, enter the Date paid. The invoice turns green and the income lands in that month on the Summary sheet.",
        "4. Add expenses on the Expenses sheet and pick a category from the drop-down.",
        "",
        "Good to know:",
        "- Income is counted when it is paid (cash basis), not when you send the invoice.",
        "- The tax set-aside is a planning estimate (profit x your rate), not tax advice. Ask an accountant what applies to you.",
        "- To look at a past year, type that year into the Settings sheet instead of the formula.",
        "- To clear the example data, select the blue cells and press Delete. Never delete whole rows, as that removes the formulas.",
        "- Built with standard formulas (SUMIFS, VLOOKUP, EDATE) that Excel, Google Sheets, LibreOffice and Apple Numbers support. Each sheet is ready for 500 rows.",
        "- Printing: every sheet prints landscape, one page wide. The Invoices and Expenses sheets print their first 60 rows. "
        "To print more, change the print area (Page Layout > Print Area).",
    ])

    # Settings -------------------------------------------------------------
    st = wb.create_sheet("Settings")
    title(st, "Settings")
    st.column_dimensions["A"].width = 34
    st.column_dimensions["B"].width = 16
    st.column_dimensions["D"].width = 30
    st["A3"], st["B3"] = "Year to report on", "=YEAR(TODAY())"
    st["A4"], st["B4"] = "Tax set-aside rate", 0.25
    st["A5"], st["B5"] = "Default payment terms (days)", 30
    st["B4"].number_format = "0%"
    st["D2"] = "Expense categories (rename freely)"
    st["D2"].font = Font(bold=True)
    for i, cat in enumerate(CATEGORIES, start=3):
        st[f"D{i}"] = cat
    paint(st, "B", 3, 5, INPUT_FILL)
    paint(st, "D", 3, 2 + len(CATEGORIES), INPUT_FILL)
    cat_range = f"=Settings!$D$3:$D${2 + len(CATEGORIES)}"

    # Invoices -------------------------------------------------------------
    inv = wb.create_sheet("Invoices")
    header(inv, 1, ["Invoice #", "Client", "Description", "Issue date", "Due date", "Amount",
                    "Date paid", "Status", "Days overdue"],
           [12, 24, 32, 13, 13, 14, 13, 12, 14])
    inv.freeze_panes = "A2"
    last = ROWS + 1
    for r in range(2, last + 1):
        inv[f"E{r}"] = f'=IF(D{r}="","",D{r}+Settings!$B$5)'
        inv[f"H{r}"] = (f'=IF(F{r}="","",IF(G{r}<>"","Paid",IF(E{r}="","Sent",'
                        f'IF(E{r}<TODAY(),"Overdue","Sent"))))')
        inv[f"I{r}"] = f'=IF(H{r}="Overdue",TODAY()-E{r},"")'
    paint(inv, "ABCDFG", 2, last, INPUT_FILL)
    paint(inv, "EHI", 2, last, CALC_FILL)
    for r in range(2, last + 1):
        for col in "DEG":
            inv[f"{col}{r}"].number_format = DATE
        inv[f"F{r}"].number_format = MONEY
    inv.conditional_formatting.add(f"H2:H{last}", FormulaRule(formula=['H2="Paid"'], fill=GOOD_FILL))
    inv.conditional_formatting.add(f"H2:H{last}", FormulaRule(formula=['H2="Overdue"'], fill=BAD_FILL))
    if with_sample:
        sample = [
            ("INV-001", "Northwind Studio", "Brand refresh, part 1", 75, 1800, 30),
            ("INV-002", "Alder & Finch", "Website copy", 52, 950, 16),
            ("INV-003", "Kestrel Labs", "Monthly retainer", 40, 2400, None),
            ("INV-004", "Northwind Studio", "Brand refresh, part 2", 12, 1800, None),
            ("INV-005", "Bright Pantry", "Menu design", 5, 400, None),
        ]
        for r, (num, client, desc, age, amount, paid_ago) in enumerate(sample, start=2):  # ages in days
            inv[f"A{r}"], inv[f"B{r}"], inv[f"C{r}"] = num, client, desc
            inv[f"D{r}"] = f"=TODAY()-{age}"
            inv[f"F{r}"] = amount
            if paid_ago is not None:
                inv[f"G{r}"] = f"=TODAY()-{paid_ago}"

    # Expenses -------------------------------------------------------------
    ex = wb.create_sheet("Expenses")
    header(ex, 1, ["Date", "Vendor", "Category", "Amount", "Notes"], [13, 26, 26, 14, 40])
    ex.freeze_panes = "A2"
    paint(ex, "ABCDE", 2, last, INPUT_FILL)
    for r in range(2, last + 1):
        ex[f"A{r}"].number_format = DATE
        ex[f"D{r}"].number_format = MONEY
    dv = DataValidation(type="list", formula1=cat_range, allow_blank=True)
    ex.add_data_validation(dv)
    dv.add(f"C2:C{last}")
    if with_sample:
        for r, (ago, vendor, cat, amount, note) in enumerate([
            (60, "Adobe", "Software & subscriptions", 59.99, "Creative suite"),
            (41, "Laptop Co", "Equipment", 1299.00, "New laptop"),
            (22, "Co-working Space", "Home office", 180.00, "Day passes"),
            (9, "Stripe", "Bank & payment fees", 31.40, "Processing fees"),
        ], start=2):
            ex[f"A{r}"] = f"=TODAY()-{ago}"
            ex[f"B{r}"], ex[f"C{r}"], ex[f"D{r}"], ex[f"E{r}"] = vendor, cat, amount, note

    # Summary --------------------------------------------------------------
    sm = wb.create_sheet("Summary", 1)
    title(sm, "Summary", "Cash basis: income counts in the month it was paid.")
    sm["A3"], sm["B3"] = "Year", "=Settings!B3"
    sm["A3"].font = Font(bold=True)
    header(sm, 5, ["Month", "Income", "Expenses", "Profit", "Suggested set-aside"], [30, 16, 16, 16, 22])
    inv_amt, inv_paid = f"Invoices!$F$2:$F${last}", f"Invoices!$G$2:$G${last}"
    ex_amt, ex_date = f"Expenses!$D$2:$D${last}", f"Expenses!$A$2:$A${last}"
    for m in range(1, 13):
        r = 5 + m
        sm[f"A{r}"] = f"=DATE($B$3,{m},1)"
        sm[f"A{r}"].number_format = "mmm yyyy"
        sm[f"B{r}"] = f'=SUMIFS({inv_amt},{inv_paid},">="&A{r},{inv_paid},"<"&EDATE(A{r},1))'
        sm[f"C{r}"] = f'=SUMIFS({ex_amt},{ex_date},">="&A{r},{ex_date},"<"&EDATE(A{r},1))'
        sm[f"D{r}"] = f"=B{r}-C{r}"
        sm[f"E{r}"] = f"=MAX(0,D{r})*Settings!$B$4"
    sm["A18"] = "Year total"
    sm["B18"], sm["C18"] = "=SUM(B6:B17)", "=SUM(C6:C17)"
    sm["D18"] = "=B18-C18"
    sm["E18"] = "=MAX(0,D18)*Settings!$B$4"
    for col in "ABCDE":
        sm[f"{col}18"].font = Font(bold=True)
    paint(sm, "ABCDE", 6, 18, CALC_FILL)
    for r in range(6, 19):
        for col in "BCDE":
            sm[f"{col}{r}"].number_format = MONEY
    sm["A19"] = "The year-total set-aside is worked out on full-year profit, so it can differ from the sum of the months."
    sm["A19"].font = Font(italic=True, color="666666")

    sm["G5"], sm["H5"] = "Money owed to you", "Amount"
    for c in ("G5", "H5"):
        sm[c].font = Font(bold=True, color="FFFFFF")
        sm[c].fill = HEADER_FILL
    status = f"Invoices!$H$2:$H${last}"
    rows = [
        ("Sent, not yet due", f'=SUMIFS({inv_amt},{status},"Sent")'),
        ("Overdue", f'=SUMIFS({inv_amt},{status},"Overdue")'),
        ("Total outstanding", "=H6+H7"),
        ("Overdue invoices (count)", f'=COUNTIF({status},"Overdue")'),
    ]
    for r, (label, formula) in enumerate(rows, start=6):
        sm[f"G{r}"], sm[f"H{r}"] = label, formula
        sm[f"H{r}"].number_format = MONEY if r < 9 else "0"
    paint(sm, "GH", 6, 9, CALC_FILL)
    sm.column_dimensions["G"].width = 28
    sm.column_dimensions["H"].width = 16

    sm["A22"], sm["B22"] = "Expenses by category (year)", "Amount"
    for c in ("A22", "B22"):
        sm[c].font = Font(bold=True, color="FFFFFF")
        sm[c].fill = HEADER_FILL
    for i in range(len(CATEGORIES)):
        r = 23 + i
        sm[f"A{r}"] = f"=Settings!D{3 + i}"
        sm[f"B{r}"] = (f'=SUMIFS({ex_amt},Expenses!$C$2:$C${last},A{r},{ex_date},">="&DATE($B$3,1,1),'
                       f'{ex_date},"<"&DATE($B$3+1,1,1))')
        sm[f"B{r}"].number_format = MONEY
    paint(sm, "AB", 23, 22 + len(CATEGORIES), CALC_FILL)

    chart = BarChart()
    chart.title = "Income vs expenses"
    chart.height, chart.width = 8, 18
    chart.add_data(Reference(sm, min_col=2, max_col=3, min_row=5, max_row=17), titles_from_data=True)
    chart.set_categories(Reference(sm, min_col=1, min_row=6, max_row=17))
    sm.add_chart(chart, "G12")

    finish(wb, list_sheets=("Invoices", "Expenses"))
    return wb


# --------------------------------------------------------------------------
# Subscription Auditor
# --------------------------------------------------------------------------
CYCLES = [("Weekly", "=52/12"), ("Every 2 weeks", "=26/12"), ("Monthly", 1),
          ("Quarterly", "=1/3"), ("Every 6 months", "=1/6"), ("Yearly", "=1/12")]
USAGE = ["Daily", "Weekly", "Monthly", "Rarely", "Never"]
SUB_CATS = ["Entertainment", "Software", "News & media", "Health & fitness",
            "Cloud & storage", "Education", "Finance", "Home & utilities", "Other", "Custom"]


def subscription_auditor(with_sample):
    wb = Workbook()
    start_here(wb, "Subscription Auditor", [
        "What this does:",
        "List everything you pay for on repeat. The Dashboard shows what it costs per month and per year, what renews soon, "
        "and how much you could save by cutting what you barely use.",
        "",
        "How to use it (10 minutes, once):",
        "1. Go through your bank and card statements for the last 3 months and add each recurring charge on the Subscriptions sheet.",
        "2. Enter the cost per charge, pick the billing cycle, and enter the next renewal date.",
        "3. Pick how often you really use it. Be honest.",
        "4. Mark each one Keep, Review or Cancel. Keep means you have decided to keep it, so it is left out of the savings figure.",
        "5. Check the Flag column and the Dashboard.",
        "",
        "Good to know:",
        "- Flags: Renews soon (14 days or less), Low use - review (Rarely or Never used), Update renewal date (the date has passed), Cancelling.",
        "- Potential savings = yearly cost of everything marked Cancel, plus everything used Rarely or Never that you have not marked Keep.",
        "- You can rename the categories and add your own on the Lists sheet.",
        "- To clear the example data, select the blue cells and press Delete. Never delete whole rows, as that removes the formulas.",
        "- Built with standard formulas (SUMIFS, VLOOKUP, EDATE) that Excel, Google Sheets, LibreOffice and Apple Numbers support. Room for 200 subscriptions.",
        "- Printing: every sheet prints landscape, one page wide. The Subscriptions sheet prints its first 60 rows. "
        "To print more, change the print area (Page Layout > Print Area).",
    ])

    ls = wb.create_sheet("Lists")
    title(ls, "Lists")
    header(ls, 3, ["Billing cycle", "Months factor"], [22, 16])
    for i, (name, factor) in enumerate(CYCLES, start=4):
        ls[f"A{i}"], ls[f"B{i}"] = name, factor
        ls[f"B{i}"].number_format = "0.0000"
    ls["D3"], ls["E3"] = "Categories", "Usage"
    for c in ("D3", "E3"):
        ls[c].font = Font(bold=True, color="FFFFFF")
        ls[c].fill = HEADER_FILL
    ls.column_dimensions["D"].width = 22
    ls.column_dimensions["E"].width = 14
    for i, cat in enumerate(SUB_CATS, start=4):
        ls[f"D{i}"] = cat
    for i, use in enumerate(USAGE, start=4):
        ls[f"E{i}"] = use
    paint(ls, "A", 4, 3 + len(CYCLES), CALC_FILL)
    paint(ls, "D", 4, 3 + len(SUB_CATS), INPUT_FILL)
    cycle_rng = f"=Lists!$A$4:$A${3 + len(CYCLES)}"
    cat_rng = f"=Lists!$D$4:$D${3 + len(SUB_CATS)}"
    use_rng = f"=Lists!$E$4:$E${3 + len(USAGE)}"
    factor_tbl = f"Lists!$A$4:$B${3 + len(CYCLES)}"

    sub = wb.create_sheet("Subscriptions", 1)
    header(sub, 1, ["Service", "Category", "Cost per charge", "Billing cycle", "Next renewal",
                    "How often used", "Decision", "Monthly cost", "Yearly cost", "Days to renewal", "Flag"],
           [26, 18, 14, 16, 14, 15, 12, 14, 14, 13, 22])
    sub.freeze_panes = "B2"
    last = 201
    for r in range(2, last + 1):
        sub[f"H{r}"] = f'=IF(OR(C{r}="",D{r}=""),"",C{r}*VLOOKUP(D{r},{factor_tbl},2,FALSE))'
        sub[f"I{r}"] = f'=IF(H{r}="","",H{r}*12)'
        sub[f"J{r}"] = f'=IF(E{r}="","",E{r}-TODAY())'
        sub[f"K{r}"] = (f'=IF(A{r}="","",IF(G{r}="Cancel","Cancelling",IF(AND(J{r}<>"",J{r}<0),"Update renewal date",'
                        f'IF(OR(F{r}="Rarely",F{r}="Never"),"Low use - review",IF(AND(J{r}<>"",J{r}<=14),"Renews soon","")))))')
    paint(sub, "ABCDEFG", 2, last, INPUT_FILL)
    paint(sub, "HIJK", 2, last, CALC_FILL)
    for r in range(2, last + 1):
        sub[f"C{r}"].number_format = MONEY
        sub[f"E{r}"].number_format = DATE
        sub[f"H{r}"].number_format = MONEY
        sub[f"I{r}"].number_format = MONEY
        sub[f"J{r}"].number_format = "0"
    for rng, formula in ((f"B2:B{last}", cat_rng), (f"D2:D{last}", cycle_rng), (f"F2:F{last}", use_rng),
                         (f"G2:G{last}", '"Keep,Review,Cancel"')):
        dv = DataValidation(type="list", formula1=formula, allow_blank=True)
        sub.add_data_validation(dv)
        dv.add(rng)
    sub.conditional_formatting.add(f"K2:K{last}", FormulaRule(formula=['K2<>""'], fill=WARN_FILL))
    sub.conditional_formatting.add(f"G2:G{last}", FormulaRule(formula=['G2="Cancel"'], fill=BAD_FILL))
    sub.conditional_formatting.add(f"G2:G{last}", FormulaRule(formula=['G2="Keep"'], fill=GOOD_FILL))
    if with_sample:
        for r, (name, cat, cost, cycle, due, use, decision) in enumerate([
            ("StreamFlix", "Entertainment", 15.49, "Monthly", 5, "Weekly", "Keep"),
            ("Cloud storage 2TB", "Cloud & storage", 99.99, "Yearly", 120, "Daily", "Keep"),
            ("Gym membership", "Health & fitness", 39.00, "Monthly", 20, "Rarely", None),
            ("Language app", "Education", 12.99, "Monthly", 11, "Never", "Cancel"),
            ("News site", "News & media", 8.00, "Monthly", -3, "Monthly", None),
            ("Design software", "Software", 54.99, "Monthly", 26, "Daily", "Keep"),
        ], start=2):
            sub[f"A{r}"], sub[f"B{r}"], sub[f"C{r}"], sub[f"D{r}"] = name, cat, cost, cycle
            sub[f"E{r}"] = f"=TODAY(){due:+d}" if due else "=TODAY()"
            sub[f"F{r}"] = use
            if decision:
                sub[f"G{r}"] = decision

    db = wb.create_sheet("Dashboard", 1)
    title(db, "Dashboard")
    db.column_dimensions["A"].width = 40
    db.column_dimensions["B"].width = 18
    db.column_dimensions["C"].width = 18
    sh, si, sj = (f"Subscriptions!${c}$2:${c}${last}" for c in "HIJ")
    sc, sf, sg = (f"Subscriptions!${c}$2:${c}${last}" for c in "CFG")
    sb = f"Subscriptions!$B$2:$B${last}"
    tiles = [
        ("Active subscriptions", f"=COUNTA(Subscriptions!$A$2:$A${last})", "0"),
        ("Total per month", f"=SUM({sh})", MONEY),
        ("Total per year", f"=SUM({si})", MONEY),
        ("Renewing in the next 30 days (count)", f'=COUNTIFS({sj},">=0",{sj},"<=30")', "0"),
        ("Renewing in the next 30 days (amount)", f'=SUMIFS({sc},{sj},">=0",{sj},"<=30")', MONEY),
        ("Potential yearly savings",
         f'=SUMIFS({si},{sg},"Cancel")'
         f'+SUMIFS({si},{sf},"Never",{sg},"<>Cancel",{sg},"<>Keep")'
         f'+SUMIFS({si},{sf},"Rarely",{sg},"<>Cancel",{sg},"<>Keep")', MONEY),
    ]
    for r, (label, formula, fmt) in enumerate(tiles, start=3):
        db[f"A{r}"], db[f"B{r}"] = label, formula
        db[f"B{r}"].number_format = fmt
        db[f"A{r}"].font = Font(bold=True)
    paint(db, "AB", 3, 2 + len(tiles), CALC_FILL)
    db["A11"], db["B11"], db["C11"] = "Category", "Per month", "Per year"
    for c in ("A11", "B11", "C11"):
        db[c].font = Font(bold=True, color="FFFFFF")
        db[c].fill = HEADER_FILL
    for i in range(len(SUB_CATS)):
        r = 12 + i
        db[f"A{r}"] = f"=Lists!D{4 + i}"
        db[f"B{r}"] = f"=SUMIFS({sh},{sb},A{r})"
        db[f"C{r}"] = f"=SUMIFS({si},{sb},A{r})"
        db[f"B{r}"].number_format = db[f"C{r}"].number_format = MONEY
    paint(db, "ABC", 12, 11 + len(SUB_CATS), CALC_FILL)
    chart = BarChart()
    chart.type = "bar"
    chart.title = "Yearly cost by category"
    chart.legend = None
    chart.height, chart.width = 9, 16
    chart.add_data(Reference(db, min_col=3, min_row=11, max_row=11 + len(SUB_CATS)), titles_from_data=True)
    chart.set_categories(Reference(db, min_col=1, min_row=12, max_row=11 + len(SUB_CATS)))
    db.add_chart(chart, "E3")

    finish(wb, list_sheets=("Subscriptions",))
    return wb


def main():
    targets = [
        ("freelancer-money-tracker", "freelancer-money-tracker", freelancer_tracker),
        ("subscription-auditor", "subscription-auditor", subscription_auditor),
    ]
    for slug, stem, build in targets:
        out = ROOT / "products" / slug / "files"
        out.mkdir(parents=True, exist_ok=True)
        for suffix, sample in (("example", True), ("blank", False)):
            path = out / f"{stem}-{suffix}.xlsx"
            build(sample).save(path)
            print("wrote", path.relative_to(ROOT))


if __name__ == "__main__":
    main()
