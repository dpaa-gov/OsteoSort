// A result table backed by the server: paging, search and sorting are done
// there, so a batch of any size stays quick in the browser.

import { getJSON, showError } from "./common.js";

const PAGE_SIZE = 10;

export class ResultTable {
    constructor(container, jobId, name) {
        this.container = container;
        this.base = `api/jobs/${jobId}`;
        this.name = name;
        this.state = { offset: 0, search: "", sort: 0, dir: "asc" };
        this.total = 0;
        container.innerHTML = `
            <div class="table-toolbar">
                <a class="btn btn-gold btn-sm" href="${this.base}/download?table=${name}" download="${name}.csv"><i class="os-icon icon-download"></i> Download</a>
                <label>Search: <input type="search" class="form-control form-control-sm"></label>
            </div>
            <div class="table-responsive"><table class="table table-striped result-table"><thead><tr></tr></thead><tbody></tbody></table></div>
            <div class="table-footer"><div class="table-count"></div><ul class="pagination pagination-sm"></ul></div>`;
        let timer;
        container.querySelector("input").addEventListener("input", (event) => {
            clearTimeout(timer);
            timer = setTimeout(() => {
                this.state.search = event.target.value;
                this.state.offset = 0;
                this.load();
            }, 250);
        });
        this.load();
    }

    async load() {
        const { offset, search, sort, dir } = this.state;
        const query = new URLSearchParams({ table: this.name, offset, limit: PAGE_SIZE, search, sort, dir });
        const request = (this.request = (this.request ?? 0) + 1);
        let page;
        try {
            page = await getJSON(`${this.base}/rows?${query}`);
        } catch (error) {
            if (request === this.request) showError(error.message);
            return;
        }
        if (request !== this.request) return; // a newer search, sort or page has been asked for
        this.total = page.total;
        // The reference breakdown is not a column on screen: it shows when the
        // sample size is hovered, and it is in the download.
        const hidden = page.columns.indexOf("reference");
        const sample = page.columns.indexOf("n");
        this.renderHead(page.columns, hidden);
        const body = this.container.querySelector("tbody");
        body.replaceChildren();
        for (const row of page.rows) {
            const tr = body.insertRow();
            row.forEach((cell, index) => {
                if (index === hidden) return;
                const td = tr.insertCell();
                td.textContent = cell ?? "";
                if (index === sample && hidden >= 0 && row[hidden]) td.dataset.tooltip = row[hidden];
            });
        }
        if (!page.rows.length) {
            const cell = body.insertRow().insertCell();
            cell.colSpan = page.columns.length - (hidden >= 0 ? 1 : 0);
            cell.className = "text-center text-muted";
            cell.textContent = page.total ? "No matching records found" : "No data available in table";
        }
        this.renderFooter(page);
    }

    renderHead(columns, hidden) {
        const row = this.container.querySelector("thead tr");
        row.replaceChildren();
        columns.forEach((column, index) => {
            if (index === hidden) return;
            const th = document.createElement("th");
            const number = index + 1;
            th.textContent = column;
            th.className = "sortable" + (this.state.sort === number ? ` sorted-${this.state.dir}` : "");
            th.addEventListener("click", () => {
                const same = this.state.sort === number;
                this.state.dir = same && this.state.dir === "asc" ? "desc" : "asc";
                this.state.sort = number;
                this.state.offset = 0;
                this.load();
            });
            row.append(th);
        });
    }

    renderFooter(page) {
        const first = page.filtered ? this.state.offset + 1 : 0;
        const last = Math.min(this.state.offset + PAGE_SIZE, page.filtered);
        let info = `Showing ${first} to ${last} of ${page.filtered.toLocaleString()} entries`;
        if (page.filtered !== page.total) info += ` (filtered from ${page.total.toLocaleString()} total entries)`;
        this.container.querySelector(".table-count").textContent = info;

        const pages = Math.max(1, Math.ceil(page.filtered / PAGE_SIZE));
        const current = Math.floor(this.state.offset / PAGE_SIZE) + 1;
        const list = this.container.querySelector(".pagination");
        list.replaceChildren();
        const add = (label, target, { active = false, disabled = false } = {}) => {
            const item = document.createElement("li");
            item.className = "page-item" + (active ? " active" : "") + (disabled ? " disabled" : "");
            const link = document.createElement("button");
            link.type = "button";
            link.className = "page-link";
            link.textContent = label;
            if (!disabled && !active) {
                link.addEventListener("click", () => {
                    this.state.offset = (target - 1) * PAGE_SIZE;
                    this.load();
                });
            }
            item.append(link);
            list.append(item);
        };
        add("Previous", current - 1, { disabled: current === 1 });
        for (const number of pageNumbers(current, pages)) {
            if (number === null) add("…", 0, { disabled: true });
            else add(String(number), number, { active: number === current });
        }
        add("Next", current + 1, { disabled: current === pages });
    }
}

// 1 2 3 4 5 … 36, with the window following the current page
function pageNumbers(current, pages) {
    if (pages <= 7) return Array.from({ length: pages }, (_, i) => i + 1);
    if (current <= 4) return [1, 2, 3, 4, 5, null, pages];
    if (current >= pages - 3) return [1, null, pages - 4, pages - 3, pages - 2, pages - 1, pages];
    return [1, null, current - 1, current, current + 1, null, pages];
}
