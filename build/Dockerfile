# syntax=docker/dockerfile:1
# Compiles OSJ, the server and their dependencies into a standalone program
# with its own Julia runtime. Run by .github/workflows/release.yml.
#
#   docker build -f build/Dockerfile --output type=local,dest=dist .

ARG JULIA_VERSION=1.13.1
FROM julia:${JULIA_VERSION}-bookworm AS build

ENV JULIA_DEPOT_PATH=/opt/julia-depot: \
    JULIA_PKG_PRECOMPILE_AUTO=0

# PackageCompiler links with gcc
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    rm -rf /var/lib/apt/lists/*

# Built at /app: the server's paths to its config, the page and VERSION are
# fixed at compile time, and the image puts them there.
WORKDIR /app
COPY OSJ OSJ
COPY server server
# only so that compiling exercises the code that serves the page
COPY web/index.html web/index.html
RUN julia --project=server -e 'using Pkg; Pkg.instantiate()' && \
    julia -e 'using Pkg; Pkg.add(name = "PackageCompiler", version = "2")'

# Compiled for generic x86-64, since it runs on other hardware than it is
# built on. `incremental` adds the app to the system image Julia ships with
# instead of compiling Julia's own code again first: the bundle comes out the
# same size and the build takes a third of the time.
RUN julia -e 'using PackageCompiler; \
    create_app("server", "/out/osteosort"; \
        executables = ["osteosort" => "julia_main"], \
        cpu_target = PackageCompiler.default_app_cpu_target(), \
        incremental = true, include_lazy_artifacts = true, force = true)'

# The packages bring whole installations along and only their shared
# libraries are loaded: LibPQ's holds a complete PostgreSQL (the server, psql,
# pg_dump), about 95 MB of the 110 MB this removes.
RUN cd /out/osteosort/share/julia/artifacts && \
    rm -rf */bin */sbin */include */lib/*.a */lib/pkgconfig */lib/postgresql */share/postgresql

FROM scratch
COPY --from=build /out/osteosort /osteosort
