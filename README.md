# OsteoSort

Computerized osteometric sorting. OsteoSort compares skeletal measurements against reference populations to help reassociate commingled remains: it tests whether two bones could belong to the same individual and reports the pairs that can be excluded.

- **Pair-matching:** a left bone against the right bone of the same element.
- **Articulation:** two bones that meet at a joint, such as femur and os coxa.
- **Regression:** the size of one bone predicted from another.

Each analysis runs on a single pair typed in by hand, or on a whole case file at once.

![OsteoSort](screenshot.png)

## How it is built

| Part | What it is | Where |
|---|---|---|
| OSJ | The method: a Julia package with no web or database code | `OSJ/` |
| Server | A Julia HTTP server: loads reference data, reads case files, runs OSJ, serves the page | `server/` |
| Page | Static HTML, CSS and JavaScript on Bootstrap 5 | `web/` |
| Reference data | ARDS, a PostgreSQL database, read-only | external |

The server reads the reference groups from ARDS when the page is opened, so a collection, individual or measurement switched off for OsteoSort in ARDS disappears from the app on the next page load.

Bones are listed head to toe, not by name. ARDS holds no order for bones, so the order comes from the number each measurement has in the data collection manual (the `utk2016` column of `osteometry.measurements`): a bone is placed by the lowest number among its measurements. Bones the manual does not number, such as the hand and foot bones, follow in alphabetical order.

## Using the app

1. Choose one or more **reference groups**. Selecting several pools their individuals.
2. Choose the **analysis** and the element (or pair of elements).
3. **Single:** type the measurements. **Multiple:** upload a case file; the choices narrow to what the file and the reference data both have.
4. Press **Analyze**.

**Results.** A pair is *Excluded* when its p-value is at or below alpha, otherwise *Cannot Exclude*. Hovering a row's sample size `n` shows which reference groups it came from. In the Multiple tab each table can be searched, sorted and downloaded; in the Single tab the Copy button puts the result on the clipboard.

**Rejected.** Anything that could not be compared is listed with the reason:

| Reason | Meaning |
|---|---|
| None of the selected measurements | The specimen has no value for any selected measurement |
| No measurements in common | Both specimens have measurements, but share none |
| Reference sample too small | Fewer than 10 reference individuals have the measurements the pair uses |
| The comparison could not be calculated | No p-value could be worked out, as when the reference sample does not vary at all |

**Case files.** A CSV with `accession`, `side` and `element` columns followed by one column per measurement, named with the ARDS code (`Hum_01`, `Fem_04`, ...). Download an empty one from **Files > Template**; it always lists the measurements currently enabled in ARDS. A measurement is a number above zero: a cell that is blank, `NA`, zero, negative or not a number counts as not taken. The file must be comma-separated and at most 5 MB, and one run can make at most 2,000,000 comparisons. **Files > Example** is a commingled assemblage of 1,056 specimens across 27 bones, sampled from the Chiba japanese male reference group.

## Local development

You need Docker, Julia 1.13 and a copy of ARDS.

**1. Start ARDS.** Build and load it as its own README describes, as a container named `ards-db`, then put it on a network the app can share:

```sh
docker network create osteosort-dev
docker network connect osteosort-dev ards-db
```

**2. Give the app its credentials.** Create `.env` in the repository root (it is git-ignored):

```
DB_HOST=ards-db
DB_PORT=5432
DB_NAME=ards
DB_USER=osteosort
DB_PASS=<the osteosort user's password>
```

**3. Run the server.**

```sh
dev/julia.sh -e 'using Pkg; Pkg.instantiate()'                       # first time only
dev/julia.sh -e 'using OsteoSortServer; OsteoSortServer.main()'      # http://127.0.0.1:3838/
```

`dev/julia.sh` runs Julia for the server package with the variables from `.env`. It uses the Julia 1.13 on your machine if there is one (reaching ARDS on `127.0.0.1`), and a Julia container on the `osteosort-dev` network otherwise. Changes to files in `web/` show on reload; changes to Julia code need a restart.

### Tests

All tests live in `test/`.

| What | Command | Needs |
|---|---|---|
| `test/osj`: the method, on made-up data | `PROJECT=OSJ dev/julia.sh -e 'using Pkg; Pkg.test()'` | nothing |
| `test/server`: the API against OSJ, awkward case files, combined reference groups | `dev/julia.sh -e 'using Pkg; Pkg.test()'` | ARDS |
| `test/browser`: the real page in a headless browser, compared with the API | see below | a running server |

```sh
docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/app:z" -w /app mcr.microsoft.com/playwright/python:v1.49.0-jammy \
  sh -c "pip install -q playwright==1.49.0 && python test/browser/test_ui.py"
```

The first two also run on GitHub for every push (`.github/workflows/tests.yml`), where the server's tests skip the parts that need ARDS. Each release additionally builds the image and checks that it starts and serves the page (`.github/workflows/release.yml`). The browser test is run by hand; do so after changing anything in `web/`.

`OSJ/test/runtests.jl` and `server/test/runtests.jl` are the files Julia's `Pkg.test()` looks for; each only points into `test/`.

### Scripts

| Script | Purpose |
|---|---|
| `dev/julia.sh` | Run Julia for the server (or, with `PROJECT=OSJ`, for OSJ) with the settings from `.env` |
| `dev/run-image.sh` | Compile the Julia side, build the image and run it as Atlas does, on http://127.0.0.1:3839/ |

## Configuration

Everything comes from the environment.

| Variable | Default | Meaning |
|---|---|---|
| `DB_NAME`, `DB_USER`, `DB_PASS` | required | ARDS database and read-only login |
| `DB_HOST` | `host.docker.internal` | ARDS host |
| `DB_PORT` | `5432` | ARDS port |
| `PORT` | `3838` | Port the server listens on |
| `REFERENCE_MAX_AGE_SECONDS` | `30` | How old the loaded reference data may be before a page load re-reads ARDS |

Two files in `server/config/` hold what is not in ARDS: the articulating measurement pairs (`articulation.csv`) and the bones regression is offered for (`regression_bones.csv`). `default_references.csv` lists the groups selected when the page opens.

## Deployment

OsteoSort is deployed through Atlas, which builds the `Dockerfile` in this repository and runs the image.

| Atlas setting | Value |
|---|---|
| Dockerfile path | `Dockerfile` |
| Container port | `3838` |
| Launch path | `/` |
| Health-check path | `/healthz` |
| ARDS database access | Read-only |

The image compiles nothing. The Julia side is compiled once per release into a standalone program and attached to the GitHub Release; the `Dockerfile` downloads it and adds the page. So a release must have its asset before that tag is deployed.

### Releasing

1. Set the version in `VERSION` (shown in the app header) and `ARG OSTEOSORT_VERSION=vX.Y.Z` in the `Dockerfile`. Update the citation below and in `CITATION`. Commit and push.
2. Publish a GitHub Release with tag `vX.Y.Z`.
3. `.github/workflows/release.yml` checks that `VERSION` and the `Dockerfile` match the tag, compiles the program with `build/Dockerfile`, builds the image from it, checks that it starts, and attaches `osteosort-linux-x86_64.tar.gz` to the release.
4. Once the asset is on the release, deploy tag `vX.Y.Z` in Atlas.

If the workflow fails, nothing is attached and a deploy of that tag fails at the download step. Fix the problem and re-run the workflow.

## Repository layout

```
OSJ/                  The method (Julia package)
  src/core.jl           the comparisons
  src/prepare.jl        choosing and aligning rows for an analysis
  src/analysis.jl       running comparisons and labelling results
server/               The HTTP server (Julia package)
  src/                  reference loading, case files, API, jobs
  config/               articulation pairs, regression bones, default groups
web/                  The page: index.html, css/, js/, vendored libraries, example file
test/                 All tests
  osj/                  the method, on made-up data; no database
  server/               the API against ARDS, with its case files in data/
  browser/              the page in a headless browser
build/Dockerfile      Compiles the Julia side into a standalone program
Dockerfile            What Atlas builds
.github/workflows/    tests.yml (every push), release.yml (each release)
dev/                  Local scripts
VERSION               The version shown in the app
```

## Citation

Lynch, J.J. 2026 OsteoSort. Computerized Osteometric Sorting. Version 2.0.0. Defense POW/MIA Accounting Agency, Offutt AFB, NE.

## License

GNU General Public License v2.0
