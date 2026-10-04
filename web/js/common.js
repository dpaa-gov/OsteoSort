// Shared pieces: API calls, dropdowns, the reference-data model and dialogs.
// Every URL is relative so the app works under whatever path Atlas serves it.

export const $ = (id) => document.getElementById(id);

async function request(path, options) {
    let response;
    try {
        response = await fetch(path, options);
    } catch {
        throw new Error("The server could not be reached");
    }
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
        const error = new Error(body.error || `The server returned an error (${response.status})`);
        error.status = response.status;
        throw error;
    }
    return body;
}

export const getJSON = (path) => request(path);
export const postJSON = (path, body) =>
    request(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export const capFirst = (text) => text.charAt(0).toUpperCase() + text.slice(1);

// How bones are shown: "Humerus", "Os coxa", and "Humerus-Ulna" for an
// articulating pair. The lower-case name from ARDS stays the value that is sent.
export const boneName = (value) => ({ text: value.split("-").map(capFirst).join("-") });

// --- Dialogs ---

export function showError(message) {
    $("error-text").textContent = message;
    bootstrap.Modal.getOrCreateInstance($("error-modal")).show();
}

export const progress = {
    show(text = "Starting...") {
        this.set(0, text);
        bootstrap.Modal.getOrCreateInstance($("progress-modal")).show();
    },
    set(percent, text) {
        $("progress-bar").style.width = percent + "%";
        $("progress-text").textContent = text;
    },
    hide() {
        bootstrap.Modal.getOrCreateInstance($("progress-modal")).hide();
    },
};

// --- Dropdowns (Tom Select) ---

// `describe(value)` may return { text, tooltip } to show a choice differently
// from the value that is sent to the server (measurement codes, for example).
export function makeSelect(id, onChange, describe) {
    const element = $(id);
    const chip = (data, escape) =>
        `<div${data.tooltip ? ` data-tooltip="${escape(data.tooltip)}"` : ""}>${escape(data.text)}</div>`;
    const select = new TomSelect(element, {
        render: { item: chip, option: (data, escape) => `<div>${escape(data.text)}</div>` },
        maxOptions: null,
        hidePlaceholder: true,
        hideSelected: element.multiple,
        closeAfterSelect: !element.multiple,
        // a dropdown is done once a value is picked; leaving it focused keeps its search field open
        onItemAdd() { if (!element.multiple) this.blur(); },
        onChange: () => onChange && onChange(),
    });
    select.describe = describe;
    return select;
}

// Replaces the choices. A dropdown keeps its value, and a tag list the user
// has removed tags from keeps what is left, where still valid; otherwise
// selects `fallback` (all given values for a tag list, the first for a dropdown).
export function setChoices(select, values, fallback) {
    const multiple = select.input.multiple;
    const chosen = [].concat(select.getValue()).filter(Boolean);
    const current = chosen.filter((value) => values.includes(value));
    const kept = multiple ? chosen.length < Object.keys(select.options).length : true;
    const before = JSON.stringify([].concat(select.getValue()));
    select.clear(true);
    select.clearOptions();
    select.addOptions(values.map((value) => ({ value, text: value, ...(select.describe ? select.describe(value) : {}) })));
    let selected = fallback !== undefined ? fallback : multiple ? values : values.slice(0, 1);
    if (fallback === undefined && kept && current.length) selected = current;
    select.setValue(multiple ? selected : selected[0] ?? "", true);
    select.refreshOptions(false);
    return JSON.stringify([].concat(select.getValue())) !== before;
}

export const valueOf = (select) => select.getValue();
export const valuesOf = (select) => [].concat(select.getValue()).filter(Boolean);

// --- Reference data: what the selected groups can support ---

export class Reference {
    // How a measurement code is shown: "Hum_01", with its full name as a tooltip
    describe = (code) => ({ text: capFirst(code), tooltip: this.name.get(code) ?? "" });

    constructor(meta) {
        this.meta = meta;
        this.groups = new Map(meta.groups.map((group) => [
            group.label,
            new Map(group.elements.map((e) => [e.element, new Set(e.measurements)])),
        ]));
        this.bone = new Map(meta.measurements.map((m) => [m.code, m.bone]));
        // every measurement is a length in millimetres; the tooltip is where that is said
        this.name = new Map(meta.measurements.map((m) => [m.code, m.name ? `${m.name} (mm)` : m.name]));
        this.codes = new Map();
        for (const m of meta.measurements) {
            if (!this.codes.has(m.bone)) this.codes.set(m.bone, []);
            this.codes.get(m.bone).push(m.code);
        }
    }

    labels() {
        return this.meta.groups.map((group) => group.label);
    }

    // Elements present in any selected group
    elements(labels) {
        return this.meta.bones.filter((bone) => labels.some((label) => this.groups.get(label)?.has(bone)));
    }

    // Measurements of an element with data in any selected group
    measurements(labels, bone) {
        return (this.codes.get(bone) || []).filter((code) =>
            labels.some((label) => this.groups.get(label)?.get(bone)?.has(code)));
    }

    regressionBones(labels) {
        return this.elements(labels).filter((bone) => this.meta.regression_bones.includes(bone));
    }

    // Articulating bone pairs the selected groups have data for
    pairs(labels) {
        const pairs = new Map();
        for (const { a, b } of this.meta.articulation) {
            const bonea = this.bone.get(a), boneb = this.bone.get(b);
            if (!bonea || !boneb) continue;
            if (!this.measurements(labels, bonea).includes(a) || !this.measurements(labels, boneb).includes(b)) continue;
            const label = `${bonea}-${boneb}`;
            if (!pairs.has(label)) pairs.set(label, { label, bonea, boneb, a: [], b: [] });
            const pair = pairs.get(label);
            if (!pair.a.includes(a)) pair.a.push(a);
            if (!pair.b.includes(b)) pair.b.push(b);
        }
        return [...pairs.values()];
    }
}

// --- Settings block shared by both tabs (ids prefixed "s-" or "m-") ---

// One note per ticked option, shown under the settings. A `warning` is added
// to an option's own note when it is combined with something that is allowed
// but rarely what is wanted.
function settingNotes({ absolute, yeojohnson, zeromean, tails }) {
    const notes = [];
    if (absolute) {
        notes.push({
            id: "absolute",
            text: "Absolute differences: compares the size of the differences between the two bones, ignoring which one is larger.",
            warning: tails === 2 && { id: "tails", text: "With two tails the p-value is doubled and can exceed 1, because " +
                "only large values count against a match. One tail is the usual choice." },
        });
    }
    if (yeojohnson) {
        notes.push({
            id: "yeojohnson",
            text: "Yeo-Johnson transformation: transforms the reference differences so they are closer to a normal " +
                "distribution before the test, and applies the same transformation to the specimens being compared.",
        });
    }
    if (zeromean) {
        notes.push({
            id: "zeromean",
            text: "Zero mean: tests against a reference mean of zero, not the mean measured in the reference sample. " +
                "This assumes no systematic difference between the two bones.",
            warning: absolute && { id: "zeromean-absolute", text: "This rarely fits together with Absolute differences, " +
                "which are never centred on zero." },
        });
    }
    return notes;
}

export function initSettings(prefix, analysisSelect) {
    const form = $(prefix + "form");
    const alpha = () => Number(form.querySelector(`input[name="${prefix}alpha"]:checked`).value);
    const tails = () => Number(form.querySelector(`input[name="${prefix}tails"]:checked`).value);
    const settings = () => ({
        absolute: $(prefix + "absolute").checked,
        yeojohnson: $(prefix + "yeojohnson").checked,
        zeromean: $(prefix + "zeromean").checked,
        tails: tails(),
    });
    const refresh = () => {
        const analysis = valueOf(analysisSelect);
        for (const block of form.querySelectorAll("[data-analysis]")) block.hidden = block.dataset.analysis !== analysis;
        for (const part of form.querySelectorAll(".tails-group, .ttest-settings")) part.hidden = analysis === "regression";
        // what is set, beside the heading while the settings are folded away
        const chosen = settings();
        const summary = analysis === "regression" ? [] : [
            chosen.absolute && "Absolute", chosen.yeojohnson && "Yeo-Johnson", chosen.zeromean && "Zero mean",
            chosen.tails === 1 ? "1 tail" : "2 tails",
        ];
        $(prefix + "settings-summary").textContent = [...summary, `α ${alpha()}`].filter(Boolean).join(" · ");
        const notes = analysis === "regression" ? [] : settingNotes(settings());
        $(prefix + "notes").replaceChildren(...notes.map((note) => {
            const element = document.createElement("div");
            element.className = "settings-note";
            element.dataset.note = note.id;
            element.textContent = note.text;
            if (note.warning) {
                const warning = document.createElement("span");
                warning.className = "warning";
                warning.dataset.note = note.warning.id;
                warning.textContent = " " + note.warning.text;
                element.append(warning);
                element.classList.add("has-warning");
            }
            return element;
        }));
    };
    form.addEventListener("input", refresh);
    form.addEventListener("change", refresh);
    refresh();
    return {
        refresh,
        alpha,
        settings,
    };
}

// Puts rows of text on the clipboard, tab-separated, which pastes into a
// spreadsheet as cells and into a document as a table. Returns whether it worked.
export async function copyRows(rows) {
    const text = rows.map((row) => row.map((cell) => String(cell ?? "").trim()).join("\t")).join("\n");
    try {
        await navigator.clipboard.writeText(text);
        return true;
    } catch {
        // no clipboard access (an embedded frame, or plain http): copy from a hidden text box
        const box = document.createElement("textarea");
        box.value = text;
        box.style.position = "fixed";
        box.style.opacity = "0";
        document.body.append(box);
        box.select();
        const copied = document.execCommand("copy");
        box.remove();
        return copied;
    }
}

// Shows a results panel and counts the analyses it has displayed, so the
// browser test can tell a new result from the last one
export function markRun(panel) {
    panel.hidden = false;
    panel.dataset.run = Number(panel.dataset.run || 0) + 1;
}

// --- Plots ---

// The toolbar's camera asks what size to save at. Plotly's own saves at the
// size on screen, which is rarely the size a figure is wanted at. The dialog
// starts at the size on screen and then keeps what was last asked for.
let imagePlot = null;
let imageSizeChosen = false;
function askImageSize(plot) {
    imagePlot = plot;
    if (!imageSizeChosen) {
        $("image-width").value = plot.offsetWidth;
        $("image-height").value = plot.offsetHeight;
    }
    bootstrap.Modal.getOrCreateInstance($("image-modal")).show();
}
$("image-form").addEventListener("submit", (event) => {
    event.preventDefault();
    imageSizeChosen = true;
    Plotly.downloadImage(imagePlot, {
        format: $("image-format").value, width: Number($("image-width").value), height: Number($("image-height").value),
        filename: imagePlot.dataset.filename,
    });
    bootstrap.Modal.getOrCreateInstance($("image-modal")).hide();
});

export const PLOT_CONFIG = {
    displaylogo: false,
    responsive: true,
    // the only button on the toolbar
    modeBarButtons: [[{ name: "saveImage", title: "Save plot as an image", icon: Plotly.Icons.camera, click: askImageSize }]],
};
// Shared by every plot. Toolbar colours are set explicitly so they do not
// depend on the theme's link colour. Plots stay as drawn: there is no button
// to undo a zoom, so dragging on the plot or along an axis does nothing.
export const PLOT_LAYOUT = {
    dragmode: false,
    template: { layout: { xaxis: { fixedrange: true }, yaxis: { fixedrange: true } } },
    plot_bgcolor: "#ffffff",
    paper_bgcolor: "#ffffff",
    modebar: { color: "rgba(68, 68, 68, 0.35)", activecolor: "#d4a843", bgcolor: "rgba(255, 255, 255, 0)" },
};
export const COLORS = { reference: "#3d5a73", excluded: "#cc4444", gold: "#d4a843" };

// --- Plain tables ---

export function fillTable(table, columns, rows) {
    table.replaceChildren();
    const head = table.createTHead().insertRow();
    for (const column of columns) {
        const th = document.createElement("th");
        th.textContent = column;
        head.append(th);
    }
    const body = table.createTBody();
    for (const row of rows) {
        const tr = body.insertRow();
        for (const cell of row) tr.insertCell().textContent = cell ?? "";
    }
    return body;
}
