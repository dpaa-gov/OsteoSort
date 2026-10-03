# syntax=docker/dockerfile:1
# Compiles OSJ, the server and their dependencies into a standalone program
# with its own Julia runtime. Run by .github/workflows/release.yml.
#
#   docker build -f build/Dockerfile --output type=local,dest=dist .

ARG JULIA_VERSION=1.11.9
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
RUN julia --project=server -e 'using Pkg; Pkg.instantiate()' && \
    julia -e 'using Pkg; Pkg.add(name = "PackageCompiler", version = "2")'

# Compiled for generic x86-64, since it runs on other hardware than it is
# built on. `incremental` is required on Julia 1.11: a from-scratch system
# image fails with "cannot register new atexit hook".
RUN julia -e 'using PackageCompiler; \
    create_app("server", "/out/osteosort"; \
        executables = ["osteosort" => "julia_main"], \
        cpu_target = PackageCompiler.default_app_cpu_target(), \
        incremental = true, include_lazy_artifacts = true, force = true)'

FROM scratch
COPY --from=build /out/osteosort /osteosort
