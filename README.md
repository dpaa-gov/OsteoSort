# OsteoSort 1.4.1

![Build](https://img.shields.io/badge/build-partial-yellow)

Computerized osteometric sorting application built with R/Shiny and Julia. OsteoSort uses statistical methods (pair-matching, articulation, and osteometric sorting by regression) to compare skeletal measurements against reference populations, aiding in the reassociation of commingled remains.

## Architecture

| Layer | Technology |
|-------|------------|
| Frontend | R/Shiny UI |
| Backend (statistical) | R + Julia (via JuliaCall) |
| Database | PostgreSQL (ARDS) |
| Deployment | Docker (rocker/shiny) |
| Julia sysimage | PackageCompiler.jl |

## Prerequisites

- Docker
- A running PostgreSQL instance with the ARDS osteometry schema
- A `.env` file inside `OsteoSort/` with database credentials:
  ```
  DB_HOST=<host>
  DB_PORT=<port>
  DB_USER=<user>
  DB_PASS=<password>
  ```

## Installation

```sh
git clone https://github.com/jjlynch2/OsteoSort
cd OsteoSort
docker build -t osteosort .
docker run --restart=on-failure:10 --name=osteosort -d -p 4001:3838 osteosort
docker network connect app_bridge osteosort 
```

The app will be available at `http://localhost:4001/OsteoSort`.

## Local Development (Without Docker)

### Requirements

- R 4.x with packages listed in [Dependencies](#dependencies)
- Julia 1.11+
- PostgreSQL client library (`libpq-dev` on Debian/Ubuntu)
- `.env` file in `OsteoSort/` with DB credentials (see [Prerequisites](#prerequisites))

### Run

```sh
Rscript start_dev.R
```

The app will open at `http://127.0.0.1:4001`. Julia loads without a sysimage in dev mode (slower initial startup, but no build step needed).

## Project Structure

```
OsteoSort/
├── Dockerfile
├── shiny-server.conf
├── OsteoSort/             # Shiny application
│   ├── server.r           # Server entry point
│   ├── ui.r               # UI entry point
│   ├── R/                 # Analytical R functions
│   ├── server/            # Server modules (reference, single, files, etc.)
│   ├── ui/                # UI modules
│   ├── extdata/           # Config files (articulation_config, etc.)
│   └── www/               # Static assets (CSS, JS, images)
├── OSJ/                   # Julia analytical package
│   ├── Project.toml
│   └── src/
└── sysimage/              # Julia sysimage build scripts
    ├── create_sysimage.jl
    └── execution_precompile.jl
```

## Dependencies

### R
| Package | Purpose |
|---------|---------|
| shiny | Web framework |
| htmltools | HTML generation |
| DT | Interactive data tables |
| ggplot2 | Plotting |
| dplyr | Data manipulation |
| shinyalert | Alert dialogs |
| zip | Result export |
| JuliaCall | R ↔ Julia bridge |
| DBI | Database interface |
| RPostgres | PostgreSQL driver |
| dotenv | Environment variable loading |
| plotly | Interactive plots |

### Julia (OSJ package)
| Package | Purpose |
|---------|---------|
| Statistics | Statistical functions |
| Optim | Optimization |
| Rmath | R math distributions |
| GLM | Generalized linear models |

## Citation

Lynch, J.J. 2025 OsteoSort. Computerized Osteometric Sorting. Version 1.4.1. Defense POW/MIA Accounting Agency, Offutt AFB, NE.

## TODO

1. Fix deprecated argument in GLM package
2. Julia is still installing dependencies... I missed one in the sysimage. Find out what it is.
3. Type my arrays for caching
4. Regression helper Complex... is abstract. Find new eltypes (see above)
5. Functions aren't pre-compiled. Could it be tails type is wrong? Double check what R pushes over. Push to Julia then check types.
6. Refactor `multiple.r` — apply Plotly + CSV download pattern (remove temp folder/zip workflow)
7. Clean up unused code/files after multiple.r migration (output_function.r, analytical_temp_space.r, etc.)
8. Improve single tab UI styling — data table layout for single-result display
9. Refactor Julia t-test functions — simplify the 8 TTEST variants into a single parameterized function

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE) for details.