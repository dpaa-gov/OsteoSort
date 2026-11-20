// Multiple tab: an uploaded case file compared against the reference groups.

import {
    $, getJSON, postJSON, capFirst, showError, progress, makeSelect, makeChoice, boneName, setChoices, valueOf, valuesOf,
    initSettings, fillTable, markRun, PLOT_CONFIG, PLOT_LAYOUT, COLORS, markLabel, statTile, settingsTile, plotHover,
} from "./common.js";
import { ResultTable, checkedDownload } from "./table.js";
import { initPlan, planTotal } from "./plan.js";

const NA_STRINGS = ["", " ", "NA"];
const STAGES = { queued: [10, "Starting..."], sorting: [50, "Sorting data..."], comparing: [75, "Running comparisons..."] };
const TABLES = ["not_excluded", "excluded", "rejected"];
const MAX_FILE_BYTES = 5 * 1024 ** 2; // the server refuses a larger one

// What the dropdowns and the plan need to know about the uploaded file. The
// server reads the same text again; this is only for filtering, the summary
// and counting what a test would compare.
function describeUpload(text, reference) {
    const rows = Papa.parse(text, { skipEmptyLines: true, delimiter: "," }).data;
    if (rows.length < 1 || rows[0].length <= 3) {
        throw new Error("The file needs accession, side and element columns followed by measurements");
    }
    // The id columns are found by name; a file that does not use those
    // names is read with its first three columns as accession, side, element.
    const header = rows[0].map((name) => name.trim().toLowerCase());
    const named = ["accession", "side", "element"].map((name) => header.indexOf(name));
    const [, sideAt, elementAt] = named.includes(-1) ? [0, 1, 2] : named;
    const ids = named.includes(-1) ? [0, 1, 2] : named;
    const measurementAt = header.map((_, i) => i).filter((i) => !ids.includes(i));
    const columns = measurementAt.map((i) => header[i]);
    const disabled = new Set(reference.meta.disabled_measurements);
    // lower-cased element -> { rows, sides, columns with a value, and by side how many
    // specimens have values for which columns }
    const elements = new Map();
    // a measurement is a finite number above zero, as on the server
    const isValue = (cell) => !NA_STRINGS.includes(cell) && Number.isFinite(Number(cell)) && Number(cell) > 0;
    const withValues = new Set(); // columns holding a value for any element
    let measured = 0;
    for (const row of rows.slice(1)) {
        const cells = measurementAt.map((i) => row[i] ?? "");
        if (!cells.some((cell) => !NA_STRINGS.includes(cell))) continue;
        // spaces around a side or element are dropped, as the server does
        const elementCell = (row[elementAt] ?? "").trim(), sideCell = (row[sideAt] ?? "").trim();
        const element = elementCell.toLowerCase();
        if (NA_STRINGS.includes(elementCell)) continue;
        measured += 1;
        if (!elements.has(element)) elements.set(element, { rows: 0, sides: [], columns: new Set(), bySide: new Map() });
        const entry = elements.get(element);
        entry.rows += 1;
        // "left", "Left" and "LEFT" are one side; the server compares them in lower case too
        const side = capFirst(sideCell.toLowerCase());
        if (!NA_STRINGS.includes(sideCell) && !entry.sides.includes(side)) entry.sides.push(side);
        const valued = columns.filter((_, i) => isValue(cells[i]));
        for (const column of valued) {
            entry.columns.add(column);
            withValues.add(column);
        }
        // Specimens of one side measured alike are counted together: a file
        // has few such patterns, however many specimens
        if (!NA_STRINGS.includes(sideCell) && valued.length) {
            if (!entry.bySide.has(side)) entry.bySide.set(side, new Map());
            const patterns = entry.bySide.get(side), key = valued.join(" ");
            if (!patterns.has(key)) patterns.set(key, { columns: valued, count: 0 });
            patterns.get(key).count += 1;
        }
    }
    return {
        text, columns, elements,
        rows: rows.length - 1, measured,
        unknownElements: [...elements.keys()].filter((element) => !reference.meta.bones.includes(element)),
        // Columns with values that ARDS does not have at all, such as a misspelt header. Measurements
        // ARDS has switched off for OsteoSort are left out quietly, like everything else it filters.
        unknownColumns: columns.filter((column) => withValues.has(column) && !reference.bone.has(column) && !disabled.has(column)),
    };
}

export function initMultiple(reference) {
    const meta = reference.meta;
    let upload = null;
    let tables = []; // the result tables on the page
    let currentJob = null; // the one run whose results this page holds on the server

    // Tells the server to forget a run. sendBeacon still goes out while the page is closing.
    function release(job) {
        if (job) navigator.sendBeacon(`api/jobs/${job}/release`);
    }
    // not when the browser only sets the page aside to come back to: its results would be gone on return
    window.addEventListener("pagehide", (event) => { if (!event.persisted) release(currentJob); });
    const labels = () => valuesOf(selects.reference);
    const selects = {
        reference: makeSelect("m-reference", () => refresh()),
        analysis: makeChoice("m-analysis", () => { form.refresh(); showPlan(); }),
        element: makeSelect("m-element", () => measurementChoices(), boneName),
        measurements: makeSelect("m-measurements", null, reference.describe),
        pair: makeSelect("m-pair", () => articulationChoices(), boneName),
        sideA: makeChoice("m-side-a"),
        sideB: makeChoice("m-side-b"),
        artSide: makeChoice("m-art-side"),
        elementA: makeSelect("m-element-a", () => { dependentChoices(); regressionChoices("a"); }, boneName),
        elementB: makeSelect("m-element-b", () => regressionChoices("b"), boneName),
        measurementsA: makeSelect("m-measurements-a", null, reference.describe),
        measurementsB: makeSelect("m-measurements-b", null, reference.describe),
    };
    const form = initSettings("m-", selects.analysis);

    // With a file loaded, only offer what both the file and the reference data have
    const inFile = (bones) => (upload ? bones.filter((bone) => upload.elements.has(bone)) : bones);
    // Measurements the file has at least one value for, for that element
    const inFileFor = (bone, codes) => (upload ? codes.filter((code) => upload.elements.get(bone)?.columns.has(code)) : codes);
    const measured = (bone) => inFileFor(bone, reference.measurements(labels(), bone));
    // Articulating pairs the selected groups have data for, both of whose bones are in the file
    const filePairs = () => reference.pairs(labels()).filter((pair) => !upload || (upload.elements.has(pair.bonea) && upload.elements.has(pair.boneb)));

    // The plan is a fourth analysis: several tests of the file as one run,
    // chosen in its dialog and run by Analyze like the other three. It is
    // given the form's own filters, so the two always agree on what the file
    // supports.
    const plan = initPlan({
        reference, labels, upload: () => upload, changed: () => showPlan(),
        settings: () => ({ alpha: form.alpha(), settings: form.settings() }),
        inFile, inFileFor, measured, filePairs, sidesFor,
    });
    const planning = () => valueOf(selects.analysis) === "plan";

    // While Plan is the analysis, the sidebar says what the plan holds as
    // things stand: the dialog may have changed it, or the file or reference
    // groups under it. Analyze cannot be pressed for a plan with nothing to
    // run or more than one run can make; why is said here, above it.
    const KIND_NAMES = { pairmatch: ["pair-match", "pair-matches"], articulation: ["articulation", "articulations"], regression: ["regression", "regressions"] };
    function showPlan() {
        const box = $("m-plan-summary");
        const line = (text, className) => {
            const row = document.createElement("div");
            if (className) row.className = className;
            row.textContent = text;
            return row;
        };
        const now = plan.current();
        const lines = [];
        if (!upload) {
            lines.push(line("Choose a case file to plan its tests", "quiet"));
        } else if (!now.tests.length) {
            lines.push(line("No tests chosen", "quiet"));
        } else {
            lines.push(line(planTotal(now.tests.length, now.pairs)));
            lines.push(line(Object.entries(KIND_NAMES).filter(([kind]) => now.kinds[kind])
                .map(([kind, [one, many]]) => `${now.kinds[kind]} ${now.kinds[kind] === 1 ? one : many}`).join(" \u00b7 "), "quiet"));
            if (now.over) lines.push(line(`More than the ${meta.max_comparisons.toLocaleString("en-US")} pairs one run can make`, "problem"));
        }
        if (now.unavailable) {
            lines.push(line(`${now.unavailable} ticked ${now.unavailable === 1 ? "test is" : "tests are"} not available as things are set`, "problem"));
        }
        box.replaceChildren(...lines);
        $("m-process").disabled = planning() && (!now.tests.length || now.over);
    }
    function sidesFor(...bones) {
        if (!upload) return ["Left", "Right"];
        const lists = bones.map((bone) => upload.elements.get(bone)?.sides ?? []);
        const shared = lists.reduce((a, b) => a.filter((side) => b.includes(side)));
        return shared.length ? shared : ["Left", "Right"];
    }

    function currentPair() {
        return reference.pairs(labels()).find((pair) => pair.label === valueOf(selects.pair));
    }

    function measurementChoices() {
        setChoices(selects.measurements, measured(valueOf(selects.element)), undefined);
    }

    // The measurements an articulating pair of bones is compared on are given by
    // the pair: they are shown, not chosen, each line one measurement on the first
    // bone and the one on the second it is compared with. One the file has no
    // value for is left out, and the run is then refused for want of a measurement.
    const given = { a: [], b: [] };
    function showGiven(a, b) {
        given.a = a;
        given.b = b;
        const code = (value) => {
            const label = document.createElement("span");
            if (value === undefined) {
                label.className = "absent";
                label.textContent = "not in the file";
                return label;
            }
            const { text, tooltip } = reference.describe(value);
            label.className = "code";
            label.textContent = text;
            if (tooltip) label.dataset.tooltip = tooltip;
            return label;
        };
        $("m-art").replaceChildren(...Array.from({ length: Math.max(a.length, b.length) }, (_, i) => {
            const line = document.createElement("div");
            const with_ = document.createElement("span");
            with_.className = "with";
            with_.textContent = "\u2194";
            line.append(code(a[i]), with_, code(b[i]));
            return line;
        }));
    }

    function articulationChoices() {
        const pair = currentPair();
        showGiven(pair ? inFileFor(pair.bonea, pair.a) : [], pair ? inFileFor(pair.boneb, pair.b) : []);
        selects.artSide.setAvailable(pair ? sidesFor(pair.bonea, pair.boneb) : ["Left", "Right"]);
    }

    function regressionChoices(which) {
        const bone = valueOf(which === "a" ? selects.elementA : selects.elementB);
        setChoices(which === "a" ? selects.measurementsA : selects.measurementsB, measured(bone));
        (which === "a" ? selects.sideA : selects.sideB).setAvailable(bone ? sidesFor(bone) : ["Left", "Right"]);
    }

    function dependentChoices() {
        const bones = inFile(reference.regressionBones(labels())).filter((bone) => bone !== valueOf(selects.elementA));
        setChoices(selects.elementB, bones);
        regressionChoices("b");
    }

    function refresh() {
        setChoices(selects.element, inFile(reference.elements(labels())));
        measurementChoices();
        setChoices(selects.pair, filePairs().map((pair) => pair.label));
        articulationChoices();
        setChoices(selects.elementA, inFile(reference.regressionBones(labels())));
        regressionChoices("a");
        dependentChoices();
        showPlan();
    }

    // A file chosen or cleared: what it holds is said, and its plan starts empty
    function showUploadSummary() {
        const box = $("m-upload-summary");
        box.hidden = !upload;
        box.replaceChildren();
        $("m-plan-open").hidden = !upload;
        plan.reset();
        if (!upload) return;
        const line = (label, text, className) => {
            const row = document.createElement("div");
            if (className) row.className = className;
            const strong = document.createElement("strong");
            strong.textContent = label + " ";
            row.append(strong, text);
            box.append(row);
        };
        const known = [...upload.elements].filter(([element]) => meta.bones.includes(element));
        line("Rows:", `${upload.rows} read, ${upload.measured} with measurements`);
        line("Elements:", known.map(([element, entry]) => `${capFirst(element)} (${entry.rows})`).join(", ") || "none recognised");
        if (upload.unknownElements.length) line("Not in reference data:", upload.unknownElements.join(", "), "unmatched");
        if (upload.unknownColumns.length) line("Columns not in ARDS:", upload.unknownColumns.join(", "), "unmatched");
    }

    $("m-file").addEventListener("change", async (event) => {
        const file = event.target.files[0];
        upload = null;
        if (file) {
            try {
                if (file.size > MAX_FILE_BYTES) throw new Error("The file is too large: a case file can be at most 5 MB");
                upload = { ...describeUpload(await file.text(), reference), name: file.name };
            } catch (error) {
                event.target.value = "";
                showError(error.message);
            }
        }
        showUploadSummary();
        refresh();
    });

    $("m-clear").addEventListener("click", () => {
        release(currentJob);
        retireTables();
        currentJob = null;
        $("m-file").value = "";
        upload = null;
        $("m-results").hidden = true;
        showUploadSummary();
        refresh();
    });

    function requestBody() {
        const analysis = valueOf(selects.analysis);
        const body = { analysis, references: labels(), alpha: form.alpha(), csv: upload.text };
        if (analysis === "pairmatch") {
            return { ...body, settings: form.settings(), element: valueOf(selects.element), measurements: valuesOf(selects.measurements) };
        }
        if (analysis === "articulation") {
            const pair = currentPair();
            return { ...body, settings: form.settings(), element_a: pair?.bonea ?? "", element_b: pair?.boneb ?? "",
                side: valueOf(selects.artSide), measurements_a: given.a, measurements_b: given.b };
        }
        return { ...body, element_a: valueOf(selects.elementA), element_b: valueOf(selects.elementB),
            side_a: valueOf(selects.sideA), side_b: valueOf(selects.sideB),
            measurements_a: valuesOf(selects.measurementsA), measurements_b: valuesOf(selects.measurementsB) };
    }

    function missingMeasurements(body) {
        const lists = body.analysis === "pairmatch" ? [body.measurements] : [body.measurements_a, body.measurements_b];
        return lists.some((list) => list.length === 0);
    }

    async function waitFor(job) {
        const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        let failures = 0;
        for (;;) {
            let status;
            try {
                status = await getJSON(`api/jobs/${job}`);
                failures = 0;
            } catch (error) {
                // The run carries on on the server, so an unreachable server or a gateway
                // error is tried again; an answer such as "expired" is not.
                const temporary = error.status === undefined || error.status >= 500;
                if (!temporary || ++failures > 10) throw error;
                await pause(1000);
                continue;
            }
            if (status.status === "done") return status;
            if (status.status === "error") throw new Error(status.error);
            // a plan says which of its tests it is on
            if (status.stage === "comparing" && status.steps > 1) {
                progress.set(50 + 45 * (status.step - 1) / status.steps, `Running test ${status.step} of ${status.steps}...`);
            } else {
                progress.set(...(STAGES[status.stage] ?? STAGES.queued));
            }
            await pause(300);
        }
    }

    // The tables on the page give way: to another test's, another run's, or nothing
    function retireTables() {
        for (const table of tables) table.retire();
        tables = [];
    }

    // One analysis as it is shown: its headline numbers, its p-values and its
    // tables. `found` is a run's status or that of one test of a plan, `body`
    // what it was made with, and `test` the number of a plan's test.
    function showAnalysis(job, found, body, test) {
        retireTables();
        markRun($("m-results"));
        const ran = !found.error;
        $("m-summary-panel").hidden = $("m-tables-panel").hidden = !ran;
        if (!ran) return;
        const s = found.summary;
        // Potential matches is what the run is for and carries the accent; the
        // last tile is what the run was made with.
        $("m-summary").replaceChildren(...[
            ["Comparisons", s.comparisons], ["Specimens", s.specimens], ["Potential matches", s.potential_matches, "", "accent"],
            ["Exclusions", s.exclusions, s.exclusion_percent === null ? "" : `${s.exclusion_percent}%`],
            ["Rejected", s.rejected],
        ].map(statTile), settingsTile(body));
        $("m-run").textContent = `Completed in ${s.seconds.toFixed(2)} seconds`;

        const h = found.histogram;
        const centres = h.excluded.map((_, i) => (i + 0.5) * h.bin_width);
        const bars = (y, name, color) => ({ x: centres, y, name, type: "bar", width: h.bin_width, marker: { color }, opacity: 0.8 });
        plotHover("m-histogram");
        Plotly.react("m-histogram", [
            bars(h.excluded, "Excluded", COLORS.excluded),
            bars(h.cannot_exclude, "Cannot Exclude", COLORS.reference),
        ], {
            barmode: "stack",
            shapes: [{ type: "line", x0: h.alpha, x1: h.alpha, y0: 0, y1: 1, yref: "paper",
                line: { color: COLORS.gold, dash: "dash", width: 2 } }],
            annotations: [markLabel(h.alpha, `α = ${h.alpha}`)],
            xaxis: { title: { text: "p" }, range: [0, 1] },
            yaxis: { title: { text: "Count" } },
            legend: { orientation: "h", x: 0.5, xanchor: "center", y: 1.1, traceorder: "normal" },
            margin: { t: 30, b: 40, l: 50, r: 10 },
            ...PLOT_LAYOUT,
        }, PLOT_CONFIG);

        tables = TABLES.map((name) => new ResultTable($(`m-pane-${name}`), job, name, test));
    }

    function renderResults(job, status, body) {
        $("m-plan-panel").hidden = true;
        $("m-test-name").textContent = "";
        showAnalysis(job, status, body);
    }

    // A plan's results: the test that is picked, shown as a single run is,
    // between its summary and its tables a line for each test with its
    // headline numbers, to pick from. Above those lines, each kind of table
    // can be downloaded for every test at once, as one list.
    for (const link of $("m-plan-downloads").querySelectorAll("a")) link.addEventListener("click", checkedDownload);
    const PLAN_COLUMNS = [["Comparisons", "comparisons"], ["Potential matches", "potential_matches"], ["Exclusions", "exclusions"], ["Rejected", "rejected"]];
    function renderPlan(job, status, chosen) {
        const body = $("m-plan-table").tBodies[0];
        const pick = (index) => {
            // Already shown: its page, sort and search stay as they are. One
            // that did not come up whole, a table of it failing to load, is
            // shown again, which is how it is tried again.
            const whole = tables.length === TABLES.length && !tables.some((table) => table.failed);
            if (body.rows[index].classList.contains("picked") && whole) return;
            [...body.rows].forEach((row, i) => {
                row.classList.toggle("picked", i === index);
                row.querySelector("button")?.setAttribute("aria-pressed", String(i === index));
            });
            const asked = chosen.tests[index];
            $("m-test-name").textContent = asked.title;
            // a regression has no settings of its own
            showAnalysis(job, status.tests[index], { alpha: chosen.alpha, settings: asked.analysis === "regression" ? undefined : chosen.settings }, index + 1);
        };
        body.replaceChildren(...status.tests.map((found, index) => {
            const row = document.createElement("tr");
            const name = row.insertCell();
            if (found.error) {
                // nothing to show for it but why
                name.textContent = chosen.tests[index].title;
                const why = row.insertCell();
                why.colSpan = PLAN_COLUMNS.length;
                why.className = "plan-failed";
                why.textContent = found.error;
                return row;
            }
            const button = document.createElement("button");
            button.type = "button";
            button.className = "plan-pick";
            button.textContent = chosen.tests[index].title;
            name.append(button);
            for (const [, key] of PLAN_COLUMNS) {
                const cell = row.insertCell();
                cell.className = "num";
                cell.textContent = found.summary[key].toLocaleString("en-US");
            }
            row.addEventListener("click", () => pick(index));
            return row;
        }));
        for (const link of $("m-plan-downloads").querySelectorAll("a")) {
            const name = link.dataset.table;
            const rows = status.tests.reduce((sum, found) => sum + (found.tables[name]?.total ?? 0), 0);
            link.href = `api/jobs/${job}/download?${new URLSearchParams({ test: "all", table: name })}`;
            link.querySelector(".count").textContent = rows.toLocaleString("en-US");
            // nothing to download where no test has a row of that kind
            link.classList.toggle("disabled", rows === 0);
            link.setAttribute("aria-disabled", String(rows === 0));
            link.tabIndex = rows === 0 ? -1 : 0;
        }
        const ran = status.tests.filter((found) => !found.error).length;
        $("m-plan-run").textContent = `${ran} of ${status.tests.length} tests completed in ${status.seconds.toFixed(2)} seconds`;
        $("m-plan-panel").hidden = false;
        const first = status.tests.findIndex((found) => !found.error);
        if (first >= 0) return pick(first);
        $("m-test-name").textContent = "";
        showAnalysis(job, { error: true });
    }

    // Starts a run, waits for it and shows what it found
    async function start(path, body, render) {
        progress.show();
        try {
            // the run names the one it replaces, so the server makes room for it without counting that one
            const { job } = await postJSON(path, { ...body, replaces: currentJob ?? undefined });
            release(currentJob); // the previous run's results are replaced by this one
            retireTables();
            currentJob = job;
            $("m-results").hidden = true; // they are gone from the server, whether or not this run succeeds
            render(job, await waitFor(job));
        } catch (error) {
            showError(error.message);
        } finally {
            progress.hide();
        }
    }

    $("m-form").addEventListener("submit", (event) => {
        event.preventDefault();
        if (!upload) return showError("Choose a case file to upload first");
        if (planning()) return runPlan();
        const body = requestBody();
        if (missingMeasurements(body)) return showError("The measurement data is missing");
        start("api/multiple", body, (job, status) => renderResults(job, status, body));
    });

    // What is ticked in the plan, with the alpha and settings as they are when Analyze is pressed
    function runPlan() {
        const chosen = { tests: plan.current().tests, alpha: form.alpha(), settings: form.settings() };
        if (!chosen.tests.length) return showError("Choose at least one test for the plan");
        const body = { references: labels(), alpha: chosen.alpha, settings: chosen.settings, csv: upload.text,
            tests: chosen.tests.map((test) => test.request) };
        start("api/plan", body, (job, status) => renderPlan(job, status, chosen));
    }

    // The histogram is drawn while its tab may be hidden; size it when shown
    document.getElementById("nav-multiple").addEventListener("shown.bs.tab", () => {
        if (!$("m-results").hidden) Plotly.Plots.resize("m-histogram");
    });

    setChoices(selects.reference, reference.labels(), meta.default_references);
    refresh();
}
