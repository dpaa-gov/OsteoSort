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

Reference data is re-read from ARDS when the page is opened, so anything switched off for OsteoSort there is gone from the app on the next page load.

## Using the app

1. Choose one or more **reference groups**. Selecting several pools their individuals.
2. Choose the **analysis** and the element (or pair of elements).
3. **Single:** type the measurements. **Multiple:** upload a case file; the choices narrow to what the file and the reference data both have.
4. Press **Analyze**.

**Results.** A pair is *Excluded* when its p-value is at or below alpha, otherwise *Cannot Exclude*. Hovering a row's sample size `n` shows which reference groups it came from. Multiple's tables can be searched, sorted and downloaded; Single's **Copy** copies the result.

**Rejected.** Anything that could not be compared is listed with the reason:

| Reason | Meaning |
|---|---|
| None of the selected measurements | The specimen has no value for any selected measurement |
| No measurements in common | Both specimens have measurements, but share none |
| Reference sample too small | Fewer than 10 reference individuals have the measurements the pair uses |
| The comparison could not be calculated | No p-value could be worked out, as when the reference sample does not vary at all |

**Case files.** A CSV with `accession`, `side` and `element` columns, then one column per measurement named with its ARDS code (`Hum_01`, `Fem_04`, ...). **Files > Template** is an empty one with the measurements currently enabled in ARDS; **Files > Example** is a commingled assemblage of 1,056 specimens. A cell that is blank, `NA`, zero, negative or not a number counts as not taken.

Limits: 5 MB per file, 10,000,000 cells (rows × measurement columns), and 2,000,000 comparisons per run.

**How long results are kept.** A Multiple run's results stay on the server until the page clears them, starts another run or is closed, or for an hour after they were last used. The server holds 2,000,000 result rows across all users. When a new run needs room, results not used in the last 15 minutes are dropped, least recently used first; results in use are never dropped, so if they leave no room the new run is refused with a time to try again.

## Local development

You need Docker, Julia 1.13 and a copy of ARDS running as a container named `ards-db`.

```sh
docker network create osteosort-dev
docker network connect osteosort-dev ards-db
```

Create `.env` in the repository root (git-ignored), with no quotes around the values:

```
DB_HOST=ards-db
DB_PORT=5432
DB_NAME=ards
DB_USER=osteosort
DB_PASS=<the osteosort user's password>
```

Run the server:

```sh
dev/julia.sh -e 'using Pkg; Pkg.instantiate()'                       # first time only
dev/julia.sh -e 'using OsteoSortServer; OsteoSortServer.main()'      # http://127.0.0.1:3838/
```

Changes in `web/` show on reload; changes to Julia code need a restart. `dev/run-image.sh` compiles the Julia side, builds the image and runs it as Atlas does, on http://127.0.0.1:3839/.

### Tests

| What | Command | Needs |
|---|---|---|
| `test/osj`: the method | `PROJECT=OSJ dev/julia.sh -e 'using Pkg; Pkg.test()'` | nothing |
| `test/server`: the API and case files | `dev/julia.sh -e 'using Pkg; Pkg.test()'` | ARDS |
| `test/browser`: the page in a headless browser | below | a running server |

```sh
docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/app:z" -w /app mcr.microsoft.com/playwright/python:v1.49.0-jammy \
  sh -c "pip install -q playwright==1.49.0 && python test/browser/test_ui.py"
```

The first two run on GitHub for every push; there the server's tests skip the parts that need ARDS.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DB_NAME`, `DB_USER`, `DB_PASS` | required | ARDS database and read-only login |
| `DB_HOST` | `host.docker.internal` | ARDS host |
| `DB_PORT` | `5432` | ARDS port |
| `PORT` | `3838` | Port the server listens on |
| `REFERENCE_MAX_AGE_SECONDS` | `30` | How old the loaded reference data may be before a page load re-reads ARDS |

`server/config/` holds what is not in ARDS: the articulating measurement pairs (`articulation.csv`), the bones regression is offered for (`regression_bones.csv`), and the groups selected when the page opens (`default_references.csv`).

## Deployment

OsteoSort is deployed through Atlas, which builds the `Dockerfile` and runs the image.

| Atlas setting | Value |
|---|---|
| Dockerfile path | `Dockerfile` |
| Container port | `3838` |
| Launch path | `/` |
| Health-check path | `/healthz` |
| ARDS database access | Read-only |

The image compiles nothing: the `Dockerfile` downloads the compiled Julia side from the GitHub Release for its tag. So a release must have its asset before that tag is deployed.

### Releasing

1. Set the version in `VERSION` and `ARG OSTEOSORT_VERSION=vX.Y.Z` in the `Dockerfile`. Update the citation here and in `CITATION`. Commit and push.
2. Publish a GitHub Release with tag `vX.Y.Z`.
3. The release workflow checks the versions match the tag, compiles the program, checks the image starts, and attaches `osteosort-linux-x86_64.tar.gz` to the release.
4. Once the asset is on the release, deploy the tag in Atlas.

If the workflow fails, nothing is attached and a deploy of that tag fails at the download step. Fix the problem and re-run the workflow.

## Citation

Lynch, J.J. 2026 OsteoSort. Computerized Osteometric Sorting. Version 2.0.0. Defense POW/MIA Accounting Agency, Offutt AFB, NE.

## License

GNU General Public License v2.0
