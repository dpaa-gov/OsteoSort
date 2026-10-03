"""Drives the real page in a headless browser against a running server.

    docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD:/app:z" -w /app mcr.microsoft.com/playwright/python:v1.49.0-jammy \
        sh -c "pip install -q playwright==1.49.0 && python test/browser/test_ui.py [URL]"

URL defaults to http://127.0.0.1:3838/. What the page shows is compared with
what the API returns for the same input; the API itself is tested in
test/server. Screenshots are written to test/browser/screens.
"""
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

from playwright.sync_api import expect, sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATA = ROOT / "test" / "server" / "data"
SCREENS = ROOT / "test" / "browser" / "screens"
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3838/"

SETTINGS = {"absolute": False, "yeojohnson": False, "zeromean": False, "tails": 2}
LEFT_HUMERUS = {"hum_01": 306, "hum_02": 63, "hum_03": 45, "hum_04": 23, "hum_05": 20,
                "hum_06": 43.9, "hum_07": 42.7, "hum_08": 16.9, "hum_09": 21.5}
RIGHT_HUMERUS = {"hum_01": 306, "hum_02": 63, "hum_03": 42.6, "hum_04": 22.1, "hum_05": 16,
                 "hum_06": 48.2, "hum_07": 45.2, "hum_08": 17.7, "hum_09": 25.1}
LEFT_FEMUR = {"fem_01": 489, "fem_02": 483, "fem_03": 92, "fem_04": 49, "fem_05": 30, "fem_06": 28,
              "fem_07": 30, "fem_14": 25.3, "fem_15": 28.4, "fem_16": 34.2, "fem_17": 32.5}


# ---------- the API, for the expected values ----------

def api(path, body=None):
    request = urllib.request.Request(URL + path, json.dumps(body).encode() if body is not None else None,
                                     {"Content-Type": "application/json"})
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def api_batch(body):
    """Run a batch through the API; returns its status and every row of each table."""
    job = api("api/multiple", body)["job"]
    while True:
        status = api(f"api/jobs/{job}")
        if status["status"] != "running":
            break
        time.sleep(0.05)
    assert status["status"] == "done", status
    tables = {}
    for name, table in status["tables"].items():
        rows = []
        while len(rows) < table["total"]:
            rows += api(f"api/jobs/{job}/rows?table={name}&offset={len(rows)}&limit=1000")["rows"]
        tables[name] = rows
    return status, tables


def held(job):
    """Whether the server still holds a run's results."""
    try:
        api(f"api/jobs/{job}")
        return True
    except urllib.error.HTTPError as error:
        assert error.code == 404, error
        return False


def last_job():
    """The id of the run the page started most recently."""
    return [re.search(r"/api/jobs/([0-9a-f]+)", line).group(1) for line in LOG if "/api/jobs/" in line][-1]


def shown(cells):
    """An API row as the page shows it: numbers and text alike, nothing for null."""
    return ["" if cell is None else cell for cell in cells]


def same(page_cells, api_cells):
    """Compare cells on the page with API values, numbers as numbers."""
    if len(page_cells) != len(api_cells):
        return False
    for text, value in zip(page_cells, shown(api_cells)):
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if float(text) != value:
                return False
        elif text != value:
            return False
    return True


# ---------- the page ----------

def choose(page, select_id, value):
    """Pick a value in a dropdown the way a user does."""
    page.locator(f"#{select_id} + .ts-wrapper .ts-control").click()
    page.locator(f"#{select_id} + .ts-wrapper .ts-dropdown .option", has_text=value).filter(
        has=page.locator("xpath=self::*[normalize-space()='%s']" % value)).first.click()


def chosen(page, select_id):
    return page.evaluate("id => [].concat(document.getElementById(id).tomselect.getValue())", select_id)


def choices(page, select_id):
    return page.evaluate("id => Object.keys(document.getElementById(id).tomselect.options)", select_id)


def table_rows(page, selector):
    return page.locator(f"{selector} tbody tr").evaluate_all(
        "rows => rows.map(row => [...row.cells].map(cell => cell.textContent))")


def process(page, prefix):
    """Click Analyze and wait for the new result to be on screen."""
    runs = page.locator(f"#{prefix}-results").get_attribute("data-run") or "0"
    page.locator(f"#{prefix}-process").click()
    expect(page.locator(f"#{prefix}-results")).not_to_have_attribute("data-run", runs, timeout=30000)
    expect(page.locator("#progress-modal")).to_be_hidden()


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("ok  ", message)


LOG = []  # browser problems and API traffic, printed if a check fails


def run(page):
    problems = []
    page.on("console", lambda m: LOG.append(f"console {m.type}: {m.text}"))
    page.on("pageerror", lambda e: LOG.append(f"page error: {e}"))
    page.on("response", lambda r: LOG.append(f"{r.request.method} {r.status} {r.url}") if "/api/" in r.url else None)
    page.on("console", lambda m: problems.append(f"console {m.type}: {m.text}") if m.type in ("error", "warning") else None)
    page.on("pageerror", lambda e: problems.append(f"page error: {e}"))
    page.on("requestfailed", lambda r: problems.append(f"request failed: {r.url}"))
    external = []
    page.on("request", lambda r: external.append(r.url) if not r.url.startswith((URL, "data:", "blob:", "about:")) else None)

    meta = api("api/meta")
    references = meta["default_references"]
    common = {"references": references, "alpha": 0.1}
    page.goto(URL)
    expect(page.locator("#version")).to_have_text("v " + (ROOT / "VERSION").read_text().strip())

    # --- Single: pair-match ---
    check(chosen(page, "s-reference") == references, "default reference groups are selected")
    choose(page, "s-element", "Humerus")
    for code in LEFT_HUMERUS:
        page.fill(f"#s-{code}-left", str(LEFT_HUMERUS[code]))
        page.fill(f"#s-{code}-right", str(RIGHT_HUMERUS[code]))
    check(page.locator("#s-left .measurement").count() == len(LEFT_HUMERUS), "one input per available measurement")
    page.screenshot(path=SCREENS / "1-single-form.png", full_page=True)
    process(page, "s")
    expect(page.locator("#s-results")).to_be_visible()
    want = api("api/single", {**common, "analysis": "pairmatch", "settings": SETTINGS, "element": "humerus",
                              "left": LEFT_HUMERUS, "right": RIGHT_HUMERUS})["results"]["rows"][0]
    row = table_rows(page, "#s-table")[0]
    # the page leaves out the two accessions and keeps the reference groups for the hover
    check(same(row, want[1:3] + want[4:12]) and row[0] == "Humerus" and row[4].startswith("Hum_01 Hum_02"),
          f"single pair-match shows what the API returns: p={row[8]} {row[9]}")
    check(page.locator("#s-plot .bars path").count() > 3, "reference histogram is drawn")
    page.locator("#s-copy").click()
    expect(page.locator("#s-copy span")).to_have_text("Copied")
    copied = page.evaluate("navigator.clipboard.readText()").split("\n")
    check(copied[0].split("\t")[-3:] == ["p", "result", "reference"] and copied[1].split("\t")[-2:] == [want[11], want[12]]
          and float(copied[1].split("\t")[-3]) == want[10],
          f"Copy puts the table on the clipboard, tab-separated, with the reference groups: {copied[1][-90:]!r}")
    cell = page.locator("#s-table tbody td[data-tooltip]")
    used = cell.get_attribute("data-tooltip")
    check(used == want[12] and sum(int(part.rsplit(" ", 1)[1]) for part in used.split(", ")) == int(cell.inner_text()),
          f"hovering the sample size shows the reference groups, adding up to n: {used}")
    page.screenshot(path=SCREENS / "2-single-pairmatch.png", full_page=True)

    # notes under the settings
    note = lambda name: page.locator(f"#s-notes [data-note='{name}']")
    check(page.locator("#s-notes .settings-note").count() == 0, "no setting notes by default")
    page.check("#s-absolute")
    check(note("absolute").is_visible() and note("tails").is_visible(), "absolute explained, with the two-tails warning")
    page.check("#s-tails-1")
    check(note("absolute").is_visible() and note("tails").count() == 0, "two-tails warning gone with one tail")
    page.check("#s-yeojohnson")
    page.check("#s-zeromean")
    check(note("yeojohnson").is_visible() and note("zeromean").is_visible() and note("zeromean-absolute").is_visible(),
          "Yeo-Johnson and Zero mean explained, with the absolute + zero mean warning")
    box = page.locator("#s-form .ttest-settings").bounding_box()
    page.screenshot(path=SCREENS / "2b-setting-notes.png", full_page=True,
                    clip={"x": 0, "y": box["y"] - 30, "width": 400, "height": box["height"] + 40})
    for checkbox in ("#s-absolute", "#s-yeojohnson", "#s-zeromean"):
        page.uncheck(checkbox)
    page.check("#s-tails-2")

    # --- Single: regression ---
    choose(page, "s-analysis", "Regression")
    check(page.locator("#s-form .ttest-settings").is_hidden(), "t-test settings hidden for regression")
    choose(page, "s-element-a", "Humerus")
    check("humerus" not in choices(page, "s-element-b"), "dependent bone excludes the independent one")
    choose(page, "s-element-b", "Femur")
    for which, values in (("A", LEFT_HUMERUS), ("B", LEFT_FEMUR)):
        for code, value in values.items():
            page.fill(f"#s-{code}-{which}", str(value))
    process(page, "s")
    want = api("api/single", {**common, "analysis": "regression", "element_a": "humerus", "element_b": "femur",
                              "side_a": "Left", "side_b": "Left", "values_a": LEFT_HUMERUS, "values_b": LEFT_FEMUR})["results"]["rows"][0]
    headers = page.locator("#s-table thead th").all_text_contents()
    row = table_rows(page, "#s-table")[0]
    check(headers[-3:] == ["R²", "p", "result"] and same(row, want[1:3] + want[4:11]) and row[0] == "Humerus",
          f"single regression shows what the API returns: R²={row[-3]} p={row[-2]}")
    check(page.locator("#s-plot .scatterlayer .trace").count() == 5, "regression plot has points, line, band and specimen")
    page.screenshot(path=SCREENS / "3-single-regression.png", full_page=True)

    # --- Single: articulation ---
    choose(page, "s-analysis", "Articulation")
    choose(page, "s-pair", "Humerus-Ulna")
    page.fill("#s-hum_06-art-a", "45.5")
    page.fill("#s-uln_11-art-b", "28.7")
    process(page, "s")
    want = api("api/single", {**common, "analysis": "articulation", "settings": SETTINGS, "element_a": "humerus",
                              "element_b": "ulna", "side": "Left", "values_a": {"hum_06": 45.5}, "values_b": {"uln_11": 28.7}})["results"]["rows"][0]
    row = table_rows(page, "#s-table")[0]
    check(same(row, want[1:3] + want[4:12]) and row[4] == "Hum_06 Uln_11",
          f"single articulation shows what the API returns: p={row[8]} {row[9]}")

    # error dialog
    page.fill("#s-hum_06-art-a", "")
    page.locator("#s-process").click()
    expect(page.locator("#error-modal")).to_be_visible()
    check("No comparison could be made" in page.locator("#error-text").inner_text(), "empty input shows the error dialog")
    page.locator("#error-modal button").click()
    expect(page.locator("#error-modal")).to_be_hidden()
    expect(page.locator("#progress-modal")).to_be_hidden()

    # --- Multiple: pair-match on the classic case file ---
    classic = (DATA / "classic_case_data.csv").read_text()
    page.locator("#nav-multiple").click()
    all_elements = choices(page, "m-element")
    page.set_input_files("#m-file", DATA / "classic_case_data.csv")
    expect(page.locator("#m-upload-summary")).to_be_visible()
    summary = page.locator("#m-upload-summary").inner_text()
    check("380 read" in summary and "Os coxa (42)" in summary and "uln_06" not in summary and "not in ARDS" not in summary,
          "upload summary: " + summary.replace("\n", " | "))
    filtered = choices(page, "m-element")
    check(len(filtered) == 9 and len(all_elements) > 9 and "os coxa" in filtered,
          f"elements narrowed to the file: {len(all_elements)} -> {len(filtered)}")
    choose(page, "m-element", "Humerus")
    measurements = chosen(page, "m-measurements")
    check(measurements == list(LEFT_HUMERUS), "all available measurements selected by default")
    tag = page.locator("#m-measurements + .ts-wrapper .item").first
    check(tag.inner_text() == "Hum_01" and "Length" in tag.get_attribute("data-tooltip"),
          f"measurement tags are capitalised with a tooltip: {tag.inner_text()} = {tag.get_attribute('data-tooltip')}")
    tag.hover()
    page.screenshot(path=SCREENS / "7-measurement-tooltip.png", clip={"x": 0, "y": 330, "width": 620, "height": 240})
    # a measurement the user has removed stays removed when the reference groups change
    extra = next(label for label in choices(page, "m-reference") if label not in chosen(page, "m-reference"))
    page.evaluate("document.getElementById('m-measurements').tomselect.removeItem('hum_03')")
    page.evaluate("label => document.getElementById('m-reference').tomselect.addItem(label)", extra)
    check("hum_03" not in chosen(page, "m-measurements") and "hum_01" in chosen(page, "m-measurements"),
          f"a removed measurement stays removed after adding {extra}")
    page.evaluate("label => document.getElementById('m-reference').tomselect.removeItem(label)", extra)
    # only measurements the file has values for: the classic clavicles have no cla_02 or cla_03
    choose(page, "m-element", "Clavicle")
    offered = chosen(page, "m-measurements")
    check("cla_01" in offered and len(offered) == 7 and "cla_02" not in offered,
          f"measurements narrowed to those with values in the file: {offered}")
    choose(page, "m-element", "Humerus")
    process(page, "m")
    expect(page.locator("#m-results")).to_be_visible()
    status, tables = api_batch({**common, "analysis": "pairmatch", "settings": SETTINGS, "element": "humerus",
                                "measurements": measurements, "csv": classic})
    kept, excluded, rejected = tables["not_excluded"], tables["excluded"], tables["rejected"]
    numbers = dict(table_rows(page, "#m-summary"))
    check(numbers["Comparisons"] == str(len(kept) + len(excluded)) and numbers["Potential matches"] == str(len(kept))
          and numbers["Rejected"] == str(len(rejected)) and len(kept) > 20 and len(excluded) > 20,
          f"summary shows what the API returns: {numbers}")
    pane = "#m-pane-not_excluded"
    expect(page.locator(f"{pane} .table-count")).to_have_text(f"Showing 1 to 10 of {len(kept)} entries")
    first = table_rows(page, pane)[0]
    check(same(first, kept[0][:12]) and first[1:3] == ["Humerus", "Left"] and first[6].startswith("Hum_"),
          f"first result row shows what the API returns, capitalised: {first[1:3] + first[6:7]}")
    check(page.locator("#m-histogram .bars path").count() > 5, "p-value histogram is drawn")
    check("reference" not in page.locator(f"{pane} thead th").all_text_contents(), "no reference column on screen")
    cell = page.locator(f"{pane} tbody tr").first.locator("td[data-tooltip]")
    used = cell.get_attribute("data-tooltip")
    check(used == kept[0][12] and sum(int(part.rsplit(" ", 1)[1]) for part in used.split(", ")) == int(cell.inner_text()),
          f"each row's sample size says which reference groups it came from: {used}")
    cell.hover()
    page.screenshot(path=SCREENS / "9-reference-tooltip.png", clip={"x": 620, "y": 560, "width": 980, "height": 140})
    page.mouse.move(800, 20)
    page.screenshot(path=SCREENS / "4-multiple-pairmatch.png", full_page=True)

    page.locator(f"{pane} .page-link", has_text="2").first.click()
    expect(page.locator(f"{pane} .table-count")).to_have_text(f"Showing 11 to 20 of {len(kept)} entries")
    check(same(table_rows(page, pane)[0], kept[10][:12]), "page 2 continues where page 1 ended")
    page.locator(f"{pane} th", has_text="p").last.click()
    page.locator(f"{pane} th", has_text="p").last.click()
    expect(page.locator(f"{pane} th.sorted-desc")).to_have_text("p")
    top = max(r[10] for r in kept)
    check(float(table_rows(page, pane)[0][10]) == top, f"sorting by p descending puts {top} first")
    page.fill(f"{pane} input[type=search]", "^a$")
    expect(page.locator(f"{pane} .table-count")).to_contain_text("filtered from")
    check(all("a" in r for r in table_rows(page, pane)), "search filters the rows")

    page.get_by_role("tab", name="Excluded", exact=True).click()
    expect(page.locator("#m-pane-excluded .table-count")).to_have_text(f"Showing 1 to 10 of {len(excluded)} entries")
    with page.expect_download() as download:
        page.locator("#m-pane-excluded .btn", has_text="Download").click()
    lines = pathlib.Path(download.value.path()).read_text().splitlines()
    check(download.value.suggested_filename == "excluded.csv" and len(lines) == len(excluded) + 1
          and lines[0].endswith('"reference"'), f"download has every excluded row ({len(lines) - 1}) and the reference groups")
    page.get_by_role("tab", name="Rejected", exact=True).click()
    expect(page.locator("#m-pane-rejected .table-count")).to_have_text(f"Showing 1 to 10 of {len(rejected)} entries")
    first_run = last_job()
    check(held(first_run), "the server holds the results of the run on screen")

    # --- Multiple: regression ---
    choose(page, "m-analysis", "Regression")
    choose(page, "m-element-a", "Humerus")
    choose(page, "m-element-b", "Femur")
    sides = choices(page, "m-side-a")
    choose(page, "m-side-a", "Left")
    choose(page, "m-side-b", "Left")
    body = {**common, "analysis": "regression", "element_a": "humerus", "element_b": "femur", "side_a": "Left", "side_b": "Left",
            "measurements_a": chosen(page, "m-measurements-a"), "measurements_b": chosen(page, "m-measurements-b"), "csv": classic}
    process(page, "m")
    status, _ = api_batch(body)
    numbers = dict(table_rows(page, "#m-summary"))
    check(numbers["Comparisons"] == str(status["summary"]["comparisons"]) == "400" and sides == ["Left", "Right"],
          f"multiple regression: {numbers['Comparisons']} comparisons, sides offered {sides}")
    second_run = last_job()
    check(second_run != first_run and held(second_run) and not held(first_run),
          "a new run replaces the previous run's results on the server")

    # --- Multiple: an awkward file, and the reasons for rejection ---
    page.locator("#m-clear").click()
    check(page.locator("#m-results").is_hidden() and page.locator("#m-upload-summary").is_hidden(), "Clear resets the tab")
    page.wait_for_timeout(300)
    check(not held(second_run), "Clear frees the results on the server")
    page.set_input_files("#m-file", DATA / "edge_cases.csv")
    expect(page.locator("#m-upload-summary")).to_contain_text("humerous")
    summary = page.locator("#m-upload-summary").inner_text()
    check("Not in reference data: humerous" in summary and "Columns not in ARDS: bogus_99" in summary and "uln_06" not in summary,
          "misspelt element and unknown column are reported: " + summary.replace("\n", " | "))
    choose(page, "m-analysis", "Pair-match")
    choose(page, "m-element", "Humerus")
    process(page, "m")
    page.get_by_role("tab", name="Rejected", exact=True).click()
    page.fill("#m-pane-rejected input[type=search]", "H4")
    expect(page.locator("#m-pane-rejected .table-count")).to_contain_text("Showing 1 to 1 of 1 entries")
    row = table_rows(page, "#m-pane-rejected")[0]
    check(page.locator("#m-pane-rejected thead th").all_text_contents()[-1] == "reason"
          and row == ["H4", "Humerus", "Left", "", "", "", "None of the selected measurements"],
          f"a specimen with no measurements is listed under Rejected with the reason: {row[-1]}")
    page.fill("#m-pane-rejected input[type=search]", "No measurements in common")
    expect(page.locator("#m-pane-rejected tbody tr").first.locator("td").last).to_have_text("No measurements in common")
    check(table_rows(page, "#m-pane-rejected")[0][3] != "", "pairs with nothing in common give that reason")
    page.screenshot(path=SCREENS / "6-rejected-reasons.png", full_page=True)

    # --- The example users download ---
    example = (ROOT / "web" / "files" / "example_data.csv").read_text()
    page.locator("#m-clear").click()
    page.set_input_files("#m-file", ROOT / "web" / "files" / "example_data.csv")
    expect(page.locator("#m-upload-summary")).to_contain_text("1056 read")
    summary = page.locator("#m-upload-summary").inner_text()
    check("Not in reference data" not in summary and "not in ARDS" not in summary and "Metatarsal 1 (40)" in summary,
          "the example file loads cleanly: 1,056 specimens, every element and column recognised")
    check(len(choices(page, "m-element")) == 27, "the example covers 27 bones")
    choose(page, "m-analysis", "Pair-match")
    choose(page, "m-element", "Calcaneus")
    process(page, "m")
    numbers = dict(table_rows(page, "#m-summary"))
    check(numbers["Comparisons"] == "400" and numbers["Specimens"] == "40", f"example calcaneus pair-match: {numbers}")
    page.screenshot(path=SCREENS / "8-example-file.png", full_page=True)

    # articulation on it
    choose(page, "m-analysis", "Articulation")
    choose(page, "m-pair", "Humerus-Ulna")
    check(choices(page, "m-art-side") == ["Left", "Right"], "sides offered are those both bones have in the file")
    choose(page, "m-art-side", "Left")
    process(page, "m")
    status, _ = api_batch({**common, "analysis": "articulation", "settings": SETTINGS, "element_a": "humerus", "element_b": "ulna",
                           "side": "Left", "measurements_a": ["hum_06"], "measurements_b": ["uln_11"], "csv": example})
    numbers = dict(table_rows(page, "#m-summary"))
    check(numbers["Comparisons"] == str(status["summary"]["comparisons"]) and int(numbers["Comparisons"]) > 100,
          f"multiple articulation: {numbers['Comparisons']} comparisons")
    page.get_by_role("tab", name="Not excluded", exact=True).click()
    expect(page.get_by_role("tab", name="Not excluded", exact=True)).to_have_class(re.compile("active"))
    expect(page.get_by_role("tab", name="Rejected", exact=True)).not_to_have_class(re.compile("active"))
    page.mouse.move(800, 20)
    page.screenshot(path=SCREENS / "5-multiple-articulation.png", full_page=True)

    # --- Files menu ---
    page.locator(".dropdown-toggle").click()
    with page.expect_download() as download:
        page.locator(".files-menu a", has_text="Template").click()
    header = pathlib.Path(download.value.path()).read_text().strip().split(",")
    check(download.value.suggested_filename == "template.csv" and header[:3] == ["accession", "side", "element"]
          and len(header) == 3 + len(meta["measurements"]), "the template downloads with the current measurement columns")
    check(page.locator(".files-menu a").all_text_contents() == ["Template", "Example"], "the Files menu offers the template and the example")

    # leaving or closing the page frees its results too
    open_run = last_job()
    check(held(open_run), "results are held while the page is open")
    page.goto("about:blank")
    time.sleep(0.5)
    check(not held(open_run), "leaving or closing the page frees its results")

    check(not external, f"no requests leave the server: {external[:3]}")
    # the empty-input check above makes the browser log its expected 422
    problems = [p for p in problems if "status of 422" not in p]
    check(not problems, f"no browser errors: {problems[:5]}")


with sync_playwright() as playwright:
    SCREENS.mkdir(parents=True, exist_ok=True)
    browser = playwright.chromium.launch(args=["--no-sandbox"])
    context = browser.new_context(viewport={"width": 1600, "height": 1100}, accept_downloads=True,
                                  permissions=["clipboard-read", "clipboard-write"])
    page = context.new_page()
    page.set_default_timeout(10000)
    try:
        run(page)
        print("\nAll UI checks passed")
    except Exception:
        page.screenshot(path=SCREENS / "failure.png", full_page=True)
        print("\n".join(LOG[-15:]))
        raise
    finally:
        browser.close()
