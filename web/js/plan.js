// The analysis plan: every test the uploaded case file can support, listed in
// a dialog to be ticked and run together, a tab for each kind of analysis.
// Pair-matches and articulations are listed for the file as it is;
// regressions are added one at a time, as any bone can be set against any
// other. What is ticked runs as one run, with the
// reference groups, alpha and settings the sidebar has set for all of it.

import { $, capFirst, makeSelect, makeChoice, boneName, setChoices, valueOf, describeSettings } from "./common.js";

const SIDES = ["Left", "Right"];
const KINDS = ["pairmatch", "articulation", "regression"];

// How many of a bone's specimens on one side have a value for any of these
// measurements. Those are the ones the server compares; the rest it rejects.
function specimens(upload, bone, side, codes) {
    let count = 0;
    for (const pattern of upload.elements.get(bone)?.bySide.get(side)?.values() ?? []) {
        if (pattern.columns.some((column) => codes.includes(column))) count += pattern.count;
    }
    return count;
}

const make = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
};
const plural = (n, word) => `${n.toLocaleString("en-US")} ${word}${n === 1 ? "" : "s"}`;

// `labels()` gives the selected reference groups, `settings()` the alpha and
// settings as { alpha, settings } and `upload()` the file as described when it
// was chosen; `run(plan)` is called with what was ticked.
export function initPlan({ reference, labels, settings, upload, run }) {
    const modal = $("plan-modal");

    // What has been chosen, kept for as long as the file stays loaded. A test
    // with nothing here is as it starts: unticked, with every measurement.
    let chosen = new Map(); // a test's key -> { ticked, open, off: measurements taken out of it }
    let regressions = []; // those added: { a, sideA, b, sideB }
    let listed = { pairmatch: [], articulation: [], regression: [] };
    // How the lists are looked at: the tab in front, whether only what is
    // ticked is shown, and which tabs have their unavailable tests unfolded
    let active = "pairmatch";
    let tickedOnly = false;
    let unfolded = new Set();

    function choiceFor(key) {
        if (!chosen.has(key)) chosen.set(key, { ticked: false, open: false, off: new Set() });
        return chosen.get(key);
    }

    const name = (bone) => capFirst(bone);
    const inFile = (bones) => bones.filter((bone) => upload().elements.has(bone));
    const valued = (bone, codes) => codes.filter((code) => upload().elements.get(bone)?.columns.has(code));
    // Measurements of a bone that both the file and the selected groups have
    const measured = (bone) => valued(bone, reference.measurements(labels(), bone));
    const kept = (key, codes) => codes.filter((code) => !choiceFor(key).off.has(code));
    const regressionKey = ({ a, sideA, b, sideB }) => `regression|${a}|${sideA}|${b}|${sideB}`;

    // A test's two kinds of specimen, each [bone, side, measurements], with how many of each the file has
    const sized = (parts) => parts.map(([bone, side, codes]) => ({ bone, side, codes, count: specimens(upload(), bone, side, codes) }));

    // Why a test would compare nothing, or "" where it has something of both kinds
    function whyNothing(parts) {
        const none = parts.find((part) => part.count === 0);
        if (!none) return "";
        const which = `${none.side.toLowerCase()} ${none.bone}`;
        return !none.codes.length ? "No measurements selected" :
            upload().elements.get(none.bone)?.sides.includes(none.side) ? `No ${which} has the selected measurements` :
            `No ${which} in the file`;
    }

    // Counts what a test would compare and, where that is nothing, says why.
    // `parts` are its specimens on the measurements chosen for it, `whole` on
    // every measurement it could use. A test that compares nothing even on
    // those is `fixed`: nothing done in the dialog would make it run.
    function counted(test, parts, whole = parts) {
        const [a, b] = sized(parts);
        const given = test.reason ?? "";
        return { ...test, counts: [a.count, b.count], pairs: a.count * b.count,
            reason: given || whyNothing([a, b]), fixed: Boolean(given || whyNothing(sized(whole))) };
    }

    function pairMatch(bone) {
        const key = `pairmatch|${bone}`;
        const offered = measured(bone), used = kept(key, offered);
        return counted({
            key, kind: "pairmatch", label: name(bone), title: `Pair-match: ${name(bone)}`,
            editors: [{ label: "", codes: offered }],
            reason: offered.length ? "" : "No measurements in common with the reference data",
            request: { analysis: "pairmatch", element: bone, measurements: used },
        }, [[bone, "Left", used], [bone, "Right", used]], [[bone, "Left", offered], [bone, "Right", offered]]);
    }

    // An articulating pair's measurements come with the pair, as in the sidebar
    function articulation(pair, side) {
        const a = valued(pair.bonea, pair.a), b = valued(pair.boneb, pair.b);
        const absent = [...pair.a.filter((code) => !a.includes(code)), ...pair.b.filter((code) => !b.includes(code))];
        const label = `${name(pair.bonea)} ↔ ${name(pair.boneb)}, ${side.toLowerCase()}`;
        return counted({
            key: `articulation|${pair.label}|${side}`, kind: "articulation", label, title: `Articulation: ${label}`,
            given: [pair.a, pair.b],
            reason: a.length && b.length ? "" : `${absent.map(capFirst).join(", ")} not in the file`,
            request: { analysis: "articulation", element_a: pair.bonea, element_b: pair.boneb, side, measurements_a: a, measurements_b: b },
        }, [[pair.bonea, side, a], [pair.boneb, side, b]]);
    }

    function regression(entry) {
        const { a, sideA, b, sideB } = entry;
        const key = regressionKey(entry);
        const offeredA = measured(a), offeredB = measured(b);
        const usedA = kept(key, offeredA), usedB = kept(key, offeredB);
        const bones = reference.regressionBones(labels());
        const label = `${name(a)} (${sideA.toLowerCase()}) → ${name(b)} (${sideB.toLowerCase()})`;
        return counted({
            key, kind: "regression", label, title: `Regression: ${label}`, entry,
            editors: [{ label: name(a), codes: offeredA }, { label: name(b), codes: offeredB }],
            reason: bones.includes(a) && bones.includes(b) ? "" : "Not in the selected reference groups",
            request: { analysis: "regression", element_a: a, element_b: b, side_a: sideA, side_b: sideB,
                measurements_a: usedA, measurements_b: usedB },
        }, [[a, sideA, usedA], [b, sideB, usedB]]);
    }

    // Every test on offer: what both the file and the selected groups have
    function tests() {
        const pairs = reference.pairs(labels()).filter((pair) => upload().elements.has(pair.bonea) && upload().elements.has(pair.boneb));
        return {
            pairmatch: inFile(reference.elements(labels())).map(pairMatch),
            articulation: pairs.flatMap((pair) => SIDES.map((side) => articulation(pair, side))),
            regression: regressions.map(regression),
        };
    }

    const isTicked = (test) => choiceFor(test.key).ticked && !test.reason;
    const ticked = () => KINDS.flatMap((kind) => listed[kind]).filter(isTicked);

    // --- The dialog ---

    // A measurement code with its full name on hover
    function code(value) {
        const { text, tooltip } = reference.describe(value);
        const element = make("span", "code", text);
        if (tooltip) element.dataset.tooltip = tooltip;
        return element;
    }

    // The measurements of a test, each a button that takes it out or puts it back
    function editor(test, choice) {
        const box = make("div", "plan-editor");
        for (const { label, codes } of test.editors) {
            const group = make("div", "plan-chips");
            if (label) group.append(make("span", "plan-chips-label", label));
            for (const value of codes) {
                const { text, tooltip } = reference.describe(value);
                const chip = make("button", "plan-chip", text);
                chip.type = "button";
                chip.dataset.planId = `${test.key}|${value}`;
                if (tooltip) chip.dataset.tooltip = tooltip;
                chip.setAttribute("aria-pressed", String(!choice.off.has(value)));
                chip.addEventListener("click", () => {
                    if (!choice.off.delete(value)) choice.off.add(value);
                    render();
                });
                group.append(chip);
            }
            box.append(group);
        }
        return box;
    }

    let rows = 0; // for ids that tie each tick box to its label
    function row(test) {
        const choice = choiceFor(test.key);
        const on = choice.ticked && !test.reason;
        const element = make("div", "plan-row" + (test.reason ? " unavailable" : "") + (on ? " ticked" : ""));
        element.dataset.test = test.key;

        const check = make("input", "form-check-input");
        check.type = "checkbox";
        check.id = `plan-check-${rows += 1}`;
        check.checked = on;
        check.disabled = Boolean(test.reason);
        check.dataset.planId = `${test.key}|tick`;
        check.addEventListener("change", () => {
            choice.ticked = check.checked;
            render();
        });
        const label = make("label", "plan-name", test.label);
        label.htmlFor = check.id;
        if (test.reason) label.append(make("span", "plan-reason", test.reason));

        const count = make("span", "plan-count num", test.counts.map((n) => n.toLocaleString("en-US")).join(" × "));
        const pairs = make("span", "plan-pairs num", test.reason ? "–" : test.pairs.toLocaleString("en-US"));

        let measures;
        if (test.editors) {
            // how many of its measurements a test is to use; pressed, it lists them to choose from
            const offered = test.editors.flatMap((part) => part.codes);
            const used = offered.filter((value) => !choice.off.has(value)).length;
            const said = !offered.length ? "None" : used === offered.length ? `All ${offered.length}` : `${used} of ${offered.length}`;
            measures = make("button", "plan-measures", said);
            measures.type = "button";
            measures.disabled = !offered.length;
            measures.dataset.planId = `${test.key}|measures`;
            measures.setAttribute("aria-expanded", String(choice.open));
            measures.setAttribute("aria-label", `${said} measurements: choose`);
            measures.addEventListener("click", () => {
                choice.open = !choice.open;
                render();
            });
        } else {
            measures = make("span", "plan-given");
            const [a, b] = test.given;
            measures.append(...a.map(code), make("span", "with", "↔"), ...b.map(code));
        }

        element.append(check, label, count, pairs, measures);
        if (test.entry) {
            const remove = make("button", "plan-remove", "×");
            remove.type = "button";
            remove.setAttribute("aria-label", `Remove ${test.label}`);
            remove.addEventListener("click", () => {
                regressions = regressions.filter((entry) => entry !== test.entry);
                chosen.delete(test.key);
                render();
            });
            element.append(remove);
        }
        if (test.editors && choice.open) element.append(editor(test, choice));
        return element;
    }

    // The line a tab's unavailable tests are folded under, which opens and closes them
    function fold(kind, count) {
        const open = unfolded.has(kind);
        const button = make("button", "plan-fold", `Not available (${count})`);
        button.type = "button";
        button.dataset.planId = `${kind}|fold`;
        button.setAttribute("aria-expanded", String(open));
        button.addEventListener("click", () => {
            if (!unfolded.delete(kind)) unfolded.add(kind);
            render();
        });
        return button;
    }

    // What a tab shows. Tests the file cannot support are folded away under
    // one line at the foot, so the list is of what can be run; a regression
    // was asked for by name and always shows. With "Ticked only", just those.
    function shown(kind) {
        const all = listed[kind];
        if (tickedOnly) {
            const picked = all.filter(isTicked).map(row);
            return picked.length ? picked : [make("div", "plan-empty", "Nothing ticked here")];
        }
        const away = kind === "regression" ? [] : all.filter((test) => test.fixed);
        const rest = all.filter((test) => !away.includes(test)).map(row);
        if (!all.length) rest.push(make("div", "plan-empty", modal.querySelector(`[data-plan="${kind}"]`).dataset.empty));
        if (away.length) rest.push(fold(kind, away.length), ...(unfolded.has(kind) ? away.map(row) : []));
        return rest;
    }

    function render() {
        // the lists are made again whole, so whatever had the keyboard is found again afterwards
        const focused = document.activeElement?.dataset?.planId;
        listed = tests();
        for (const kind of KINDS) {
            const list = modal.querySelector(`[data-plan="${kind}"]`);
            list.replaceChildren(...shown(kind));
            list.hidden = kind !== active;
            // each tab says how many of its tests are ticked
            const tab = modal.querySelector(`[data-plan-tab="${kind}"]`);
            const count = listed[kind].filter(isTicked).length;
            tab.classList.toggle("active", kind === active);
            tab.setAttribute("aria-selected", String(kind === active));
            tab.querySelector(".plan-tab-count").textContent = count || "";
        }
        $("plan-builder").hidden = active !== "regression";
        const offered = listed[active].some((test) => !test.reason);
        for (const button of modal.querySelectorAll("[data-plan-tick]")) button.disabled = !offered;
        if (focused) [...modal.querySelectorAll("[data-plan-id]")].find((element) => element.dataset.planId === focused)?.focus();

        const run = ticked();
        const pairs = run.reduce((sum, test) => sum + test.pairs, 0);
        const most = reference.meta.max_comparisons;
        const over = pairs > most;
        $("plan-total").classList.toggle("over", over);
        $("plan-total").textContent = `${plural(run.length, "test")} \u00b7 ${plural(pairs, "pair")} to compare` +
            (over ? `, more than the ${most.toLocaleString("en-US")} one run can make` : "");
        $("plan-run").disabled = !run.length || over;
    }

    for (const tab of modal.querySelectorAll("[data-plan-tab]")) {
        tab.addEventListener("click", () => {
            active = tab.dataset.planTab;
            render();
        });
    }

    $("plan-ticked-only").addEventListener("change", (event) => {
        tickedOnly = event.target.checked;
        render();
    });

    // All or None ticks or clears every test the tab in front offers
    for (const button of modal.querySelectorAll("[data-plan-tick]")) {
        button.addEventListener("click", () => {
            for (const test of listed[active]) choiceFor(test.key).ticked = button.dataset.planTick === "all" && !test.reason;
            render();
        });
    }

    // --- Adding a regression ---

    const builder = {
        a: makeSelect("p-element-a", () => builderChoices(), boneName),
        b: makeSelect("p-element-b", () => builderSides(), boneName),
        sideA: makeChoice("p-side-a"),
        sideB: makeChoice("p-side-b"),
    };

    function builderSides() {
        for (const [bone, side] of [[valueOf(builder.a), builder.sideA], [valueOf(builder.b), builder.sideB]]) {
            const sides = upload().elements.get(bone)?.sides ?? [];
            side.setAvailable(sides.length ? sides : SIDES);
        }
        $("p-add").disabled = !valueOf(builder.a) || !valueOf(builder.b);
    }

    // The first bone predicts the second, which is any other
    function builderChoices() {
        const bones = inFile(reference.regressionBones(labels()));
        setChoices(builder.a, bones);
        setChoices(builder.b, bones.filter((bone) => bone !== valueOf(builder.a)));
        builderSides();
    }

    $("p-add").addEventListener("click", () => {
        const entry = { a: valueOf(builder.a), sideA: valueOf(builder.sideA), b: valueOf(builder.b), sideB: valueOf(builder.sideB) };
        const key = regressionKey(entry);
        if (!regressions.some((other) => regressionKey(other) === key)) regressions.push(entry);
        // one that was asked for by name is meant to be run
        choiceFor(key).ticked = true;
        render();
    });

    // --- Opening and running ---

    modal.addEventListener("show.bs.modal", () => {
        $("plan-file").textContent = upload().name;
        $("p-reference").textContent = labels().join(", ") || "None selected";
        // all of it, though the sidebar shows only the alpha while it is set to a regression
        const set = settings();
        $("p-settings").textContent = describeSettings(set.settings, set.alpha);
        builderChoices();
        render();
    });

    // The run starts once the dialog has gone: two dialogs changing places
    // at once leave the page unable to scroll.
    let waiting = null;
    $("plan-run").addEventListener("click", () => {
        waiting = { tests: ticked().map(({ title, kind, request }) => ({ title, analysis: kind, request })), ...settings() };
        bootstrap.Modal.getOrCreateInstance(modal).hide();
    });
    modal.addEventListener("hidden.bs.modal", () => {
        const plan = waiting;
        waiting = null;
        if (plan) run(plan);
    });

    return {
        // A different file is a different plan
        reset() {
            chosen = new Map();
            regressions = [];
            unfolded = new Set();
            active = "pairmatch";
            tickedOnly = $("plan-ticked-only").checked = false;
        },
    };
}
