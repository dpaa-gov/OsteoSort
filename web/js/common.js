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

// --- Page zoom on wide screens ---

// A screen wider than 1920px shows the page larger, by three quarters of the
// width it has beyond 1920: 1.25 times at 2560, 1.75 at 3840. (A screen the
// system already scales, such as 4K at 200%, reports its scaled width and is
// left alone.)
const DESIGN_WIDTH = 1920;
const ZOOM_SHARE = 0.75;
const zoomFor = () => 1 + ZOOM_SHARE * Math.max(0, window.innerWidth / DESIGN_WIDTH - 1);
export function fitToScreen() {
    const apply = () => {
        document.body.style.zoom = zoomFor() === 1 ? "" : String(zoomFor());
    };
    window.addEventListener("resize", apply);
    apply();
}

// --- Hover labels ---

// Plots show their own hover labels, not Plotly's: one look, in the app's
// tooltip style, at any size. Plotly's would also name the wrong point on a
// zoomed page (fitToScreen), as it places the pointer without allowing for the
// zoom; these do. A label names the point nearest the pointer, or the bar under
// it; fitted lines and intervals have none. Where the points are is worked out
// from Plotly's axes, so nothing is measured on screen.
const plotTip = document.createElement("div");
plotTip.className = "plot-tip";
plotTip.hidden = true;
document.body.append(plotTip);
document.addEventListener("scroll", () => { plotTip.hidden = true; }, true);

const NEAR = 20; // how close to a point the pointer must be, in page pixels
const hoverNumber = (value) => String(Math.round(value * 1e4) / 1e4);

// What is under the pointer at (mx, my), in the plot's own pixels: the text
// for the label and where it points, or null
function hoveredAt(gd, mx, my) {
    const fl = gd._fullLayout, xa = fl.xaxis, ya = fl.yaxis;
    const px = (x) => xa._offset + xa.d2p(x), py = (y) => ya._offset + ya.d2p(y);
    // the titles the plot was given; Plotly fills in a placeholder where there is none
    const xTitle = gd.layout.xaxis?.title?.text, yTitle = gd.layout.yaxis?.title?.text;
    let best = null;
    for (const trace of gd.calcdata) {
        const full = trace[0].trace;
        if (full.visible !== true) continue;
        if (full.type === "bar" || full.type === "histogram") {
            for (const bin of trace) {
                const lower = bin.ph0 ?? bin.p - full.width / 2, upper = bin.ph1 ?? bin.p + full.width / 2;
                const base = bin.b || 0, top = base + bin.s;
                if (!bin.s || mx < px(lower) || mx > px(upper) || my < py(top) || my > py(base)) continue;
                const range = full.type === "histogram" ? `${hoverNumber(lower)} – ${hoverNumber(upper)}` : hoverNumber(bin.p);
                return { x: px(bin.p), y: py(top), text: `${full.name}\n${xTitle || "Range"}: ${range}\nCount: ${bin.s}` };
            }
            continue;
        }
        if (!full.mode?.includes("markers")) continue; // a fitted line or an interval
        full.x.forEach((x, i) => {
            const y = full.y[i];
            const distance = Math.hypot(px(x) - mx, py(y) - my);
            if (distance <= NEAR && (!best || distance < best.distance)) {
                best = { distance, x: px(x), y: py(y), text: `${full.name}\n${xTitle || "x"}: ${hoverNumber(x)}\n${yTitle || "y"}: ${hoverNumber(y)}` };
            }
        });
    }
    return best;
}

function showHover(gd, event) {
    const zoom = zoomFor();
    if (!gd._fullLayout) {
        plotTip.hidden = true;
        return;
    }
    const r = gd.getBoundingClientRect();
    const hit = hoveredAt(gd, (event.clientX - r.left) / zoom, (event.clientY - r.top) / zoom);
    plotTip.hidden = !hit;
    if (!hit) return;
    plotTip.textContent = hit.text;
    // beside the point, on the side with room for it
    const left = r.left / zoom + hit.x, top = r.top / zoom + hit.y - plotTip.offsetHeight / 2;
    const onLeft = hit.x + 12 + plotTip.offsetWidth > gd._fullLayout.width;
    plotTip.style.left = `${onLeft ? left - 12 - plotTip.offsetWidth : left + 12}px`;
    plotTip.style.top = `${top}px`;
}

// Gives a plot these hover labels; once is enough for a plot that is redrawn
export function plotHover(id) {
    const gd = $(id);
    if (gd.dataset.plotHover) return;
    gd.dataset.plotHover = "on";
    let frame = 0, last = null;
    gd.addEventListener("mousemove", (event) => {
        last = event;
        frame ||= requestAnimationFrame(() => { frame = 0; showHover(gd, last); });
    });
    gd.addEventListener("mouseleave", () => { plotTip.hidden = true; });
}

// --- Tooltips inside things that scroll ---

// A tooltip drawn inside a scrolling list is cut off at the list's edge. For
// the scrolling measurement fields and an open dropdown list, one tooltip that
// floats over the page is placed by script from where the hovered thing is on
// screen: above a field's code, beside a name in a list. It goes when the
// pointer leaves or anything scrolls.
const floatingTip = document.createElement("div");
floatingTip.className = "floating-tip";
floatingTip.hidden = true;
document.body.append(floatingTip);
document.addEventListener("mouseover", (event) => {
    const target = event.target.closest?.(".measure-scroll [data-tooltip], .ts-dropdown .option[data-tooltip]");
    floatingTip.hidden = !target;
    if (!target) return;
    floatingTip.textContent = target.dataset.tooltip;
    // Where the hovered thing is comes in screen pixels; the tooltip is placed
    // in the page's own, which differ by the page's zoom (fitToScreen)
    const zoom = zoomFor();
    const r = target.getBoundingClientRect();
    const at = { left: r.left / zoom, right: r.right / zoom, top: r.top / zoom, height: r.height / zoom };
    const beside = target.matches(".option");
    floatingTip.style.left = `${beside ? at.right + 8 : at.left}px`;
    floatingTip.style.top = `${beside ? at.top + (at.height - floatingTip.offsetHeight) / 2 : at.top - floatingTip.offsetHeight - 6}px`;
});
document.addEventListener("scroll", () => { floatingTip.hidden = true; }, true);

// --- Dropdowns (Tom Select) ---

// `describe(value)` may return { text, tooltip } to show a choice differently
// from the value that is sent to the server (measurement codes, for example).
export function makeSelect(id, onChange, describe) {
    const element = $(id);
    const chip = (data, escape) =>
        `<div${data.tooltip ? ` data-tooltip="${escape(data.tooltip)}"` : ""}>${escape(data.text)}</div>`;
    const select = new TomSelect(element, {
        // each tag in a tag list carries a small × that takes it out
        plugins: element.multiple ? { remove_button: { title: "Remove" } } : {},
        // a measurement shows its full name on hover, as a tag and in the list
        render: { item: chip, option: chip },
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

// A choice between a few fixed options, as a row of buttons: the analysis, a
// side. Read like a dropdown (`getValue`), so the forms treat the two alike.
// An option that is not on offer, such as a side the uploaded file has no bone
// of, is greyed out and the choice moves to one that is.
export function makeChoice(id, onChange) {
    const inputs = [...$(id).querySelectorAll("input")];
    $(id).addEventListener("change", () => onChange && onChange());
    return {
        getValue: () => inputs.find((input) => input.checked).value,
        setAvailable(sides) {
            const known = inputs.some((input) => sides.includes(input.value));
            for (const input of inputs) input.disabled = known && !sides.includes(input.value);
            if (inputs.find((input) => input.checked).disabled) inputs.find((input) => !input.disabled).checked = true;
        },
    };
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

// The labels written on a plot ("Comparison", the alpha) can be taken off, for
// a figure that is captioned elsewhere. The choice holds for later plots too,
// until the button is pressed again.
let labelsHidden = false;
function toggleLabels(plot) {
    labelsHidden = !labelsHidden;
    const labels = plot.layout.annotations ?? [];
    if (labels.length) Plotly.relayout(plot, Object.fromEntries(labels.map((_, i) => [`annotations[${i}].visible`, !labelsHidden])));
}
const LABEL_ICON = { width: 24, height: 24,
    path: "M17.63 5.84C17.27 5.33 16.67 5 16 5L5 5.01C3.9 5.01 3 5.9 3 7v10c0 1.1.9 1.99 2 1.99L16 19c.67 0 1.27-.33 1.63-.84L22 12l-4.37-6.16z" };

export const PLOT_CONFIG = {
    displaylogo: false,
    responsive: true,
    // the only two buttons on the toolbar
    modeBarButtons: [[
        { name: "toggleLabels", title: "Hide or show labels", icon: LABEL_ICON, click: toggleLabels },
        { name: "saveImage", title: "Save plot as an image", icon: Plotly.Icons.camera, click: askImageSize },
    ]],
};
// Shared by every plot. Toolbar colours are set explicitly so they do not
// depend on the theme's link colour. Plots stay as drawn: there is no button
// to undo a zoom, so dragging on the plot or along an axis does nothing.
export const PLOT_LAYOUT = {
    dragmode: false,
    hovermode: false, // the app's own hover labels instead (plotHover)
    // Every tick label is shown ("allow"): Plotly hides those it measures as
    // spilling past the plot, and on a zoomed page it measures them too large
    // and hides the last on each axis.
    template: { layout: { xaxis: { fixedrange: true, ticklabeloverflow: "allow" },
                          yaxis: { fixedrange: true, ticklabeloverflow: "allow" } } },
    plot_bgcolor: "#ffffff",
    paper_bgcolor: "#ffffff",
    modebar: { color: "rgba(68, 68, 68, 0.35)", activecolor: "#d4a843", bgcolor: "rgba(255, 255, 255, 0)" },
};
export const COLORS = { reference: "#3d5a73", excluded: "#cc4444", gold: "#d4a843" };
// What a mark is, written beside it on the side with room for it: a dashed
// vertical line is labelled at its top, a point (given its y) next to it.
export const markLabel = (x, text, onLeft = false, y = null) => ({
    x, text, showarrow: false, xanchor: onLeft ? "right" : "left", xshift: onLeft ? -6 : 6,
    font: { size: 12, color: "#2a4051" }, visible: !labelsHidden,
    ...(y === null ? { y: 1, yref: "paper", yanchor: "top" } : { y, yanchor: "middle", xshift: onLeft ? -10 : 10 }),
});

// --- Stat tiles ---

// One headline figure: the value large, an optional note beside it, its label underneath
export function statTile([label, value, note, kind]) {
    const element = document.createElement("div");
    element.className = "stat-tile" + (kind ? " " + kind : "");
    const number = document.createElement("div");
    number.className = "stat-value";
    // thousands separators on whole numbers; anything else exactly as given
    number.textContent = Number.isInteger(value) ? value.toLocaleString("en-US") : String(value);
    if (note) {
        const small = document.createElement("span");
        small.className = "stat-note";
        small.textContent = note;
        number.append(small);
    }
    const name = document.createElement("div");
    name.className = "stat-label";
    name.textContent = label;
    element.append(number, name);
    return element;
}

// The settings a result was made with, read from the request that made it. The
// form can be changed afterwards; this stays with the result.
export function settingsTile(body) {
    const chosen = body.settings ?? {};
    const options = [chosen.absolute && "Absolute", chosen.yeojohnson && "Yeo-Johnson", chosen.zeromean && "Zero mean"].filter(Boolean);
    const tails = body.settings ? (chosen.tails === 1 ? "1 tail" : "2 tails") : "";
    return statTile([options.length ? "Settings: " + options.join(", ") : "Settings", `α ${body.alpha}`, tails]);
}

// --- Plain tables ---

// A cell listing the measurements a comparison used gives their number, with
// the codes on hover, so a long list does not make its row taller than the
// rest. Downloads and Copy keep the codes.
export function summariseMeasurements(cell) {
    const codes = cell.textContent.trim().split(/\s+/).filter(Boolean);
    if (!codes.length) return;
    cell.dataset.tooltip = codes.join(" ");
    cell.classList.add("measures", "num");
    cell.textContent = codes.length;
}

// Columns of numbers are set against the right edge, so their digits line up
export const NUMERIC_COLUMNS = new Set(["Measurements", "n", "Mean", "SD", "p", "R²"]);

export function fillTable(table, columns, rows) {
    table.replaceChildren();
    const head = table.createTHead().insertRow();
    for (const column of columns) {
        const th = document.createElement("th");
        th.textContent = column;
        if (NUMERIC_COLUMNS.has(column)) th.className = "num";
        head.append(th);
    }
    const body = table.createTBody();
    for (const row of rows) {
        const tr = body.insertRow();
        row.forEach((cell, i) => {
            const td = tr.insertCell();
            td.textContent = cell ?? "";
            if (NUMERIC_COLUMNS.has(columns[i])) td.className = "num";
        });
    }
    return body;
}
