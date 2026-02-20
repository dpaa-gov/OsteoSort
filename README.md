# OsteoSort 1.5.0

![Build](https://img.shields.io/badge/build-passing-brightgreen)
![R](https://img.shields.io/badge/R-4.x-blue)
![Julia](https://img.shields.io/badge/Julia-1.11+-purple)
![Status](https://img.shields.io/badge/status-beta%20testing%20needed-yellow)

Computerized osteometric sorting application built with R/Shiny and Julia. OsteoSort uses statistical methods to compare skeletal measurements against reference populations, aiding in the reassociation of commingled remains.

**Key Features:**
- **Pair-matching** — statistical comparison of bilateral skeletal elements
- **Articulation** — assessment of joint congruence between adjacent bones
- **Osteometric sorting by regression** — size-based reassociation using OLS regression
- Interactive Plotly visualizations with CSV export
- PostgreSQL-backed reference populations (ARDS)

![OsteoSort Screenshot](screenshot.png)

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
  DB_NAME=<database>
  ```

## Installation

```sh
git clone https://github.com/dpaa-gov/OsteoSort
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
| dplyr | Data manipulation |
| shinyalert | Alert dialogs |
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

## Acknowledgments

- **Alex Moore** — UI styling suggestions and design inspiration

## Citation

Lynch, J.J. 2026 OsteoSort. Computerized Osteometric Sorting. Version 1.5.0. Defense POW/MIA Accounting Agency, Offutt AFB, NE.

## TODO

1. Analysts beta test

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE) for details.