# ── Stage 1: Builder ─────────────────────────────────────────
# Compiles Julia shared library (libosj.so) and C shim
FROM debian:bookworm-slim AS builder

ARG JULIAVER=1.11.4

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget ca-certificates gcc libc6-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Julia
RUN wget -O juliaup https://install.julialang.org && \
    sh juliaup -y && \
    /root/.juliaup/bin/juliaup add $JULIAVER && \
    /root/.juliaup/bin/juliaup default $JULIAVER

ENV PATH="/root/.juliaup/bin:${PATH}"

# Copy Julia package and build scripts
COPY OSJ /build/OSJ
COPY build /build/build

WORKDIR /build

# Build the shared library
RUN julia --project=OSJ -e ' \
    using Pkg; \
    Pkg.add("PackageCompiler"); \
    using PackageCompiler; \
    println("Building libosj.so..."); \
    create_library( \
    "OSJ", \
    "dist/libosj"; \
    lib_name = "osj", \
    precompile_execution_file = "build/library_precompile.jl", \
    incremental = false, \
    filter_stdlibs = true, \
    force = true \
    ); \
    println("✓ Library build complete!") \
    '

# Build the C shim for R .C() → init_julia bridging
RUN gcc -shared -fPIC \
    -o dist/r_osj_shim.so \
    build/r_osj_shim.c \
    -L dist/libosj/lib -losj \
    -Wl,-rpath,/home/shiny/dist/libosj/lib

# ── Stage 2: Runtime ─────────────────────────────────────────
# Lean R Shiny image — no Julia installation needed
FROM rocker/shiny:4.4.3

# Copy shiny-server config
COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

# Delete example apps
RUN rm -rf /srv/shiny-server/*

# Install system deps for R packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Install R dependencies
RUN R -e "install.packages(c('dplyr', 'shinyalert', 'DT', 'htmltools', 'DBI', 'RPostgres', 'dotenv', 'plotly'))"

# Copy the Shiny app code
COPY OsteoSort /srv/shiny-server/OsteoSort

# Copy compiled shared library and shim from builder
COPY --from=builder /build/dist/libosj /home/shiny/dist/libosj
COPY --from=builder /build/dist/r_osj_shim.so /home/shiny/dist/r_osj_shim.so

# Set library path so Julia runtime libs can be found
ENV LD_LIBRARY_PATH="/home/shiny/dist/libosj/lib:/home/shiny/dist/libosj/lib/julia"

# Change ownership
RUN chown -R shiny /srv/shiny-server/OsteoSort && \
    chown -R shiny /home/shiny

# Expose the application port
EXPOSE 3838

# Start shiny-server
CMD ["shiny-server"]