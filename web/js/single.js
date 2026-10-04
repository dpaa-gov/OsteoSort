// Single tab: two typed-in specimens compared against the reference groups.

import {
    $, postJSON, capFirst, showError, progress, makeSelect, boneName, setChoices, valueOf, valuesOf,
    initSettings, fillTable, copyRows, markRun, PLOT_CONFIG, PLOT_LAYOUT, COLORS,
} from "./common.js";

export function initSingle(reference) {
    const meta = reference.meta;
    const labels = () => valuesOf(selects.reference);
    let lastTable = []; // the result as it is copied: what is shown, plus the reference breakdown

    const selects = {
        reference: makeSelect("s-reference", () => referenceChanged()),
        analysis: makeSelect("s-analysis", () => form.refresh()),
        element: makeSelect("s-element", () => renderPairMatch(), boneName),
        sideA: makeSelect("s-side-a"),
        sideB: makeSelect("s-side-b"),
        artSide: makeSelect("s-art-side"),
        elementA: makeSelect("s-element-a", () => { dependentChoices(); renderRegression("a"); }, boneName),
        elementB: makeSelect("s-element-b", () => renderRegression("b"), boneName),
        pair: makeSelect("s-pair", () => renderArticulation(), boneName),
    };
    const form = initSettings("s-", selects.analysis);

    // One labelled number field per measurement, keeping what was already typed
    function renderInputs(container, codes, suffix) {
        const typed = new Map([...container.querySelectorAll("input")].map((input) => [input.dataset.code, input.value]));
        container.replaceChildren();
        for (const code of codes) {
            const wrapper = document.createElement("div");
            wrapper.className = "measurement";
            const label = document.createElement("label");
            const text = document.createElement("span");
            text.textContent = capFirst(code);
            if (reference.name.get(code)) text.dataset.tooltip = reference.name.get(code);
            label.htmlFor = `s-${code}-${suffix}`;
            label.append(text);
            const input = document.createElement("input");
            input.type = "number";
            input.className = "form-control";
            input.id = `s-${code}-${suffix}`;
            input.dataset.code = code;
            input.min = 0;
            input.max = 999;
            input.step = "any";
            input.value = typed.get(code) ?? "";
            wrapper.append(label, input);
            container.append(wrapper);
        }
    }

    const entered = (container) => Object.fromEntries(
        [...container.querySelectorAll("input")].map((input) => [input.dataset.code, input.value === "" ? null : Number(input.value)]));

    function renderPairMatch() {
        const codes = reference.measurements(labels(), valueOf(selects.element));
        renderInputs($("s-left"), codes, "left");
        renderInputs($("s-right"), codes, "right");
    }

    function renderRegression(which) {
        const select = which === "a" ? selects.elementA : selects.elementB;
        renderInputs($("s-values-" + which), reference.measurements(labels(), valueOf(select)), which.toUpperCase());
    }

    function currentPair() {
        return reference.pairs(labels()).find((pair) => pair.label === valueOf(selects.pair));
    }

    function renderArticulation() {
        const pair = currentPair();
        renderInputs($("s-art-a"), pair ? pair.a : [], "art-a");
        renderInputs($("s-art-b"), pair ? pair.b : [], "art-b");
    }

    // Dependent cannot be the same bone as independent
    function dependentChoices() {
        const bones = reference.regressionBones(labels()).filter((bone) => bone !== valueOf(selects.elementA));
        setChoices(selects.elementB, bones);
        renderRegression("b");
    }

    function referenceChanged() {
        setChoices(selects.element, reference.elements(labels()));
        setChoices(selects.elementA, reference.regressionBones(labels()));
        setChoices(selects.pair, reference.pairs(labels()).map((pair) => pair.label));
        renderPairMatch();
        renderRegression("a");
        dependentChoices();
        renderArticulation();
    }

    function requestBody() {
        const analysis = valueOf(selects.analysis);
        const body = { analysis, references: labels(), alpha: form.alpha() };
        if (analysis === "pairmatch") {
            return { ...body, settings: form.settings(), element: valueOf(selects.element),
                left: entered($("s-left")), right: entered($("s-right")) };
        }
        if (analysis === "articulation") {
            const pair = currentPair();
            return { ...body, settings: form.settings(), element_a: pair?.bonea ?? "", element_b: pair?.boneb ?? "",
                side: valueOf(selects.artSide), values_a: entered($("s-art-a")), values_b: entered($("s-art-b")) };
        }
        return { ...body, element_a: valueOf(selects.elementA), element_b: valueOf(selects.elementB),
            side_a: valueOf(selects.sideA), side_b: valueOf(selects.sideB),
            values_a: entered($("s-values-a")), values_b: entered($("s-values-b")) };
    }

    function renderResult(result) {
        markRun($("s-results"));
        // Both specimens are the ones on screen, so their accessions are left out.
        // Which reference groups were used shows on hovering the sample size, and is copied.
        const columns = result.results.columns;
        const reference = columns.indexOf("reference");
        const copied = columns.map((column, i) => (column.startsWith("accession") ? -1 : i)).filter((i) => i >= 0);
        const shown = copied.filter((i) => i !== reference);
        const body = fillTable($("s-table"), shown.map((i) => columns[i]), result.results.rows.map((row) => shown.map((i) => row[i])));
        result.results.rows.forEach((row, r) => {
            if (reference >= 0 && row[reference]) body.rows[r].cells[shown.indexOf(columns.indexOf("n"))].dataset.tooltip = row[reference];
        });
        lastTable = [copied.map((i) => columns[i]), ...result.results.rows.map((row) => copied.map((i) => row[i]))];
        const plot = result.plot;
        const paper = { ...PLOT_LAYOUT, showlegend: false };
        if (result.analysis === "regression") {
            // no line or band when the reference sample is too small to fit one
            const line = (y, name, color, dash = "dash") =>
                ({ x: plot.band.x, y, name, type: "scatter", mode: "lines", line: { color, dash } });
            Plotly.react("s-plot", [
                { x: plot.ref_x, y: plot.ref_y, name: "Reference", type: "scatter", mode: "markers", marker: { color: "grey", size: 6 } },
                ...(plot.band ? [
                    line(plot.band.fit, "OLS", COLORS.gold, "solid"),
                    line(plot.band.lower, "Lower PI", "black"),
                    line(plot.band.upper, "Upper PI", "black"),
                ] : []),
                { x: [plot.specimen_x], y: [plot.specimen_y], name: "Specimen", type: "scatter", mode: "markers",
                  marker: { color: COLORS.gold, size: 10 } },
            ], { ...paper, xaxis: { title: { text: capFirst(plot.x_label) } }, yaxis: { title: { text: capFirst(plot.y_label) } } }, PLOT_CONFIG);
        } else {
            Plotly.react("s-plot", [
                { x: plot.reference, name: "Reference", type: "histogram",
                  marker: { color: COLORS.reference, line: { color: "grey", width: 1 } } },
            ], { ...paper, shapes: [{ type: "line", x0: plot.specimen, x1: plot.specimen, y0: 0, y1: 1, yref: "paper",
                line: { color: COLORS.gold, dash: "dash", width: 2 } }] }, PLOT_CONFIG);
        }
    }

    $("s-copy").addEventListener("click", async () => {
        const label = $("s-copy").querySelector("span");
        label.textContent = (await copyRows(lastTable)) ? "Copied" : "Copy failed";
        setTimeout(() => { label.textContent = "Copy"; }, 1500);
    });

    $("s-form").addEventListener("submit", async (event) => {
        event.preventDefault();
        progress.show("Running comparison...");
        progress.set(50, "Running comparison...");
        try {
            const result = await postJSON("api/single", requestBody());
            renderResult(result);
        } catch (error) {
            showError(error.message);
        } finally {
            progress.hide();
        }
    });

    setChoices(selects.reference, reference.labels(), meta.default_references);
    referenceChanged();
}
