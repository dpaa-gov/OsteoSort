// The plan: every test the uploaded case file can support, listed in a dialog
// to be ticked, a tab for each kind of analysis. Pair-matches and
// articulations are listed for the file as it is; regressions are added one
// at a time, as any bone can be set against any other. The dialog only
// chooses. What is ticked is run from the sidebar, by Analyze while Plan is
// the analysis there, as one run with the reference groups, alpha and
// settings the sidebar has set for all of it.

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

// How much a plan is, as the dialog and the sidebar both say it
export const planTotal = (tests, pairs) => `${plural(tests, "test")} \u00b7 ${plural(pairs, "pair")} to compare`;

// `labels()` gives the selected reference groups, `settings()` the alpha and
// settings as { alpha, settings } and `upload()` the file as described when it
// was chosen; `changed()` is called whenever what is ticked may be something
// else, so the sidebar says the same as the dialog. What the file supports is asked of the
// sidebar's own filters: `inFile(bones)`, `inFileFor(bone, codes)`,
// `measured(bone)`, `filePairs()` and `sidesFor(bone)`.
export function initPlan({ reference, labels, settings, upload, changed, inFile, inFileFor, measured, filePairs, sidesFor }) {
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
        const a = inFileFor(pair.bonea, pair.a), b = inFileFor(pair.boneb, pair.b);
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
            reason: !(bones.includes(a) && bones.includes(b)) ? "Not in the selected reference groups" :
                offeredA.length && offeredB.length ? "" : "No measurements in common with the reference data",
            request: { analysis: "regression", element_a: a, element_b: b, side_a: sideA, side_b: sideB,
                measurements_a: usedA, measurements_b: usedB },
        }, [[a, sideA, usedA], [b, sideB, usedB]]);
    }

    // Every test on offer: what both the file and the selected groups have
    function tests() {
        return {
            pairmatch: inFile(reference.elements(labels())).map(pairMatch),
            articulation: filePairs().flatMap((pair) => SIDES.map((side) => articulation(pair, side))),
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
                builderChoices(); // it can be added again
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
        // All has something to tick where the tab offers a test; None has
        // something to clear there too, or where a test of its kind is ticked
        // that the tab no longer lists
        const offered = listed[active].some((test) => !test.reason);
        const tickedHere = [...chosen].some(([key, choice]) => choice.ticked && key.startsWith(`${active}|`));
        for (const button of modal.querySelectorAll("[data-plan-tick]")) {
            button.disabled = !offered && !(button.dataset.planTick === "none" && tickedHere);
        }
        if (focused) [...modal.querySelectorAll("[data-plan-id]")].find((element) => element.dataset.planId === focused)?.focus();

        const run = ticked();
        const pairs = run.reduce((sum, test) => sum + test.pairs, 0);
        const most = reference.meta.max_comparisons;
        const over = pairs > most, tooMany = run.length > reference.meta.max_plan_tests;
        $("plan-total").classList.toggle("over", over || tooMany);
        $("plan-total").textContent = planTotal(run.length, pairs) +
            (tooMany ? `, more than the ${reference.meta.max_plan_tests} tests one plan can have` : "") +
            (over ? `, more than the ${most.toLocaleString("en-US")} pairs one run can make` : "");
        changed();
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

    // All ticks every test the tab in front offers. None clears every test
    // of the tab's kind: those it lists, and any ticked earlier that it no
    // longer does (its bone gone with a reference group, say), which could
    // not be unticked by hand. A test's key starts with its kind.
    for (const button of modal.querySelectorAll("[data-plan-tick]")) {
        button.addEventListener("click", () => {
            if (button.dataset.planTick === "all") {
                for (const test of listed[active]) choiceFor(test.key).ticked = !test.reason;
            } else {
                for (const [key, choice] of chosen) if (key.startsWith(`${active}|`)) choice.ticked = false;
            }
            render();
        });
    }

    // --- Adding a regression ---

    // A regression is two bones, each on a side. The strip offers only what
    // is not in the plan yet: a second bone is listed while some pairing of
    // sides with the first is still to be added, and a first bone while it
    // has such a second. Add says so where the pairing on show is in already.
    const builder = {
        a: makeSelect("p-element-a", () => builderChoices(), boneName),
        b: makeSelect("p-element-b", () => builderSides(), boneName),
        sideA: makeChoice("p-side-a", () => builderSides()),
        sideB: makeChoice("p-side-b", () => builderSides()),
    };

    const regressionBones = () => inFile(reference.regressionBones(labels()));
    // The sides of a bone the strip can offer: those of its two buttons that
    // the file has, as the sidebar finds them; both, where it has neither
    function sidesOf(bone) {
        const inFile = sidesFor(bone);
        const sides = SIDES.filter((side) => inFile.includes(side));
        return sides.length ? sides : SIDES;
    }
    const added = (entry) => regressions.some((other) => regressionKey(other) === regressionKey(entry));
    // The pairings of sides of two bones that are not in the plan yet
    const free = (a, b) => sidesOf(a).flatMap((sideA) => sidesOf(b).map((sideB) => ({ a, sideA, b, sideB }))).filter((entry) => !added(entry));
    // The bones a first bone can still be set against
    const seconds = (a) => regressionBones().filter((b) => b !== a && free(a, b).length);
    const onShow = () => ({ a: valueOf(builder.a), sideA: valueOf(builder.sideA), b: valueOf(builder.b), sideB: valueOf(builder.sideB) });

    function builderSides() {
        const { a, b } = onShow();
        builder.sideA.setAvailable(sidesOf(a));
        builder.sideB.setAvailable(sidesOf(b));
        const taken = Boolean(a && b) && added(onShow());
        $("p-add").disabled = !a || !b || taken;
        $("p-add").textContent = taken ? "Added" : "Add";
    }

    // The first bone predicts the second, which is any other
    function builderChoices() {
        setChoices(builder.a, regressionBones().filter((a) => seconds(a).length));
        setChoices(builder.b, seconds(valueOf(builder.a)));
        builderSides();
    }

    // After one is added the strip moves on to the next still to add: the
    // bone after the second in the list, on the same sides where the file has
    // them, so that several bones are set against one a click at a time. When
    // the list has been gone through, it is the second bone's other sides.
    function moveOn({ a, sideA, b, sideB }) {
        const bones = regressionBones().filter((bone) => bone !== a);
        const from = bones.indexOf(b);
        const next = [...bones.slice(from + 1), ...bones.slice(0, from + 1)].find((bone) => free(a, bone).length);
        builderChoices(); // the lists without what was just added
        if (!next) return; // nothing left for this first bone, which has gone from its list
        const pairing = free(a, next).find((entry) => entry.sideA === sideA && entry.sideB === sideB) ?? free(a, next)[0];
        builder.b.setValue(next, true);
        builder.sideB.setAvailable(sidesOf(next)); // a side can only be chosen once it is on offer
        builder.sideA.setValue(pairing.sideA);
        builder.sideB.setValue(pairing.sideB);
        builderSides();
    }

    $("p-add").addEventListener("click", () => {
        // (Add cannot be pressed for a pairing that is in the plan already)
        const entry = onShow();
        regressions.push(entry);
        // one that was asked for by name is meant to be run
        choiceFor(regressionKey(entry)).ticked = true;
        moveOn(entry);
        render();
    });

    // --- Opening and closing ---

    modal.addEventListener("show.bs.modal", () => {
        $("plan-file").textContent = upload().name;
        $("p-reference").textContent = labels().join(", ") || "None selected";
        // all of it, though the sidebar shows only the alpha while it is set to a regression
        const set = settings();
        $("p-settings").textContent = describeSettings(set.settings, set.alpha);
        builderChoices();
        render();
    });

    // (Closed by Done or otherwise, what is ticked stays ticked: nothing is done on closing.)

    return {
        // What Analyze would run as things stand: the ticked tests the file
        // and the selected reference groups still support, each with its
        // title and request, how many of each kind and how many pairs they
        // compare, whether that is `over` what one run can make or they are
        // `tooMany` for one plan, and how many
        // ticked tests are `unavailable`: no longer supported, as when the
        // reference groups have changed since they were ticked. Worked out
        // afresh each time, since the sidebar can change under a plan.
        current() {
            const none = { tests: [], kinds: {}, pairs: 0, over: false, tooMany: false, unavailable: 0 };
            if (!upload()) return none;
            listed = tests();
            const run = ticked();
            const keys = new Set(run.map((test) => test.key));
            const pairs = run.reduce((sum, test) => sum + test.pairs, 0);
            return {
                tests: run.map(({ title, kind, request }) => ({ title, analysis: kind, request })),
                kinds: Object.fromEntries(KINDS.map((kind) => [kind, run.filter((test) => test.kind === kind).length])),
                pairs,
                over: pairs > reference.meta.max_comparisons,
                tooMany: run.length > reference.meta.max_plan_tests,
                unavailable: [...chosen].filter(([key, choice]) => choice.ticked && !keys.has(key)).length,
            };
        },
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
