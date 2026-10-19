# syntax=docker/dockerfile:1
# Compiles OSJ, the server and their dependencies into a standalone program
# with its own Julia runtime. Run by .github/workflows/release.yml, which
# makes both of its builds.
#
# TRIM=0 is the ordinary build, by PackageCompiler: Julia whole, with the app
# added to its system image. TRIM=1 is the trimmed build, by JuliaC: only the
# code the app can be shown to reach, without Julia's compiler or the rest of
# its system image. Atlas runs the trimmed build. The ordinary one compiles in
# a few minutes where the trimmed one takes some twenty, and is what
# dev/run-image.sh runs unless asked for the other.
#
#   docker build -f build/Dockerfile --output type=local,dest=dist .
#   docker build -f build/Dockerfile --build-arg TRIM=1 --output type=local,dest=dist .

ARG TRIM=0
ARG JULIA_VERSION=1.13.1
FROM julia:${JULIA_VERSION}-bookworm AS base

ENV JULIA_DEPOT_PATH=/opt/julia-depot: \
    JULIA_PKG_PRECOMPILE_AUTO=0

# the compiled code is linked with gcc
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    rm -rf /var/lib/apt/lists/*

# Built at /app: the server's paths to its config, the page and VERSION are
# fixed at compile time, and the image puts them there.
WORKDIR /app
COPY OSJ OSJ
COPY server server

# --- The ordinary build ---

FROM base AS compile-0
# only so that compiling exercises the code that serves the page
COPY web/index.html web/index.html
RUN julia --project=server -e 'using Pkg; Pkg.instantiate()' && \
    julia -e 'using Pkg; Pkg.add(name = "PackageCompiler", version = "2")'

# Compiled for generic x86-64, since it runs on other hardware than it is
# built on. `incremental` adds the app to the system image Julia ships with
# instead of compiling Julia's own code again first: the bundle comes out the
# same size and the build takes a third of the time.
#
# `--strip-metadata` leaves docstrings and source locations out of the system
# image, Julia's own included: 86 MB less of it, and about 30 MiB less held by
# the app when idle. An error still names the app's own file and
# line, but not a place inside Julia. Nor can the app ask where its package is
# once it is running, which server/src/config.jl does when it is compiled instead.
RUN julia -e 'using PackageCompiler; \
    create_app("server", "/out/osteosort"; \
        executables = ["osteosort" => "julia_main"], \
        cpu_target = PackageCompiler.default_app_cpu_target(), \
        sysimage_build_args = `--strip-metadata`, \
        incremental = true, include_lazy_artifacts = true, force = true)'

# --- The trimmed build ---

FROM base AS compile-1
COPY build/trim build/trim
# The server is compiled from where it lies, in an environment that names it
# by its path: given the server's own project, JuliaC compiles a copy of it
# from a temporary folder, and those are then the paths fixed in the program.
RUN julia --project=/opt/trim -e 'using Pkg; \
        Pkg.develop([PackageSpec(path = "/app/server"), PackageSpec(path = "/app/OSJ")]); \
        Pkg.add(name = "JuliaC", version = "0.3")'

# `--trim=safe` refuses to build anything it cannot show to be complete
RUN julia --startup-file=no --project=/opt/trim -e 'using JuliaC; JuliaC.main(ARGS)' -- \
        --output-exe osteosort --bundle /out/osteosort --project=/opt/trim --experimental --trim=safe build/trim/entry.jl

# --- Either one, pruned ---

FROM compile-${TRIM} AS compiled
# The packages bring whole installations along and only their shared
# libraries are loaded: LibPQ's holds a complete PostgreSQL (the server, psql,
# pg_dump), about 95 MB of the 110 MB this removes.
RUN cd /out/osteosort/share/julia/artifacts && \
    rm -rf */bin */sbin */include */lib/*.a */lib/pkgconfig */lib/postgresql */share/postgresql

FROM scratch
COPY --from=compiled /out/osteosort /osteosort
