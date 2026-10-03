// Entry point: load what the dropdowns are built from, then start both tabs.

import { $, getJSON, Reference } from "./common.js";
import { initSingle } from "./single.js";
import { initMultiple } from "./multiple.js";

try {
    const meta = await getJSON("api/meta");
    $("version").textContent = "v " + meta.version;
    const reference = new Reference(meta);
    initSingle(reference);
    initMultiple(reference);
} catch (error) {
    $("load-error").textContent = error.message;
    $("load-error").hidden = false;
}
