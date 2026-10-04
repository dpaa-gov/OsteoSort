// Entry point: load what the dropdowns are built from, then start both tabs.

import { $, getJSON, Reference, progress } from "./common.js";
import { initSingle } from "./single.js";
import { initMultiple } from "./multiple.js";

// Reading the reference data from ARDS can take a few seconds. If it does, say
// so; when it is quick, nothing is shown. The forms stay hidden until their
// dropdowns are built, so they are never seen half-made.
const title = document.querySelector("#progress-modal .modal-title");
const waiting = setTimeout(() => {
    title.textContent = "Loading...";
    progress.show();
    progress.set(100, "Loading reference data...");
}, 300);
try {
    const meta = await getJSON("api/meta");
    $("version").textContent = "v " + meta.version;
    const reference = new Reference(meta);
    initSingle(reference);
    initMultiple(reference);
    $("app-content").hidden = false;
} catch (error) {
    $("load-error").textContent = error.message;
    $("load-error").hidden = false;
} finally {
    clearTimeout(waiting);
    progress.hide();
    title.textContent = "Analyzing...";
}
