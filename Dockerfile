# Lean R Shiny image — no Julia installation needed.
# libosj and the C shim are prebuilt by build/Dockerfile.libosj and attached
# to the GitHub Release for LIBOSJ_VERSION (.github/workflows/release.yml).
FROM rocker/shiny:4.4.3

# Release that provides libosj-linux-x86_64.tar.gz — bump with each release
ARG LIBOSJ_VERSION=v1.5.0-rc1
ARG LIBOSJ_URL=https://github.com/dpaa-gov/OsteoSort/releases/download/${LIBOSJ_VERSION}/libosj-linux-x86_64.tar.gz

# Copy shiny-server config
COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

# Delete example apps
RUN rm -rf /srv/shiny-server/*

# Install system deps for R packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Install R dependencies
RUN R -e "install.packages(c('dplyr', 'shinyalert', 'DT', 'htmltools', 'DBI', 'RPostgres', 'plotly'))"

# Download and unpack the prebuilt shared library and shim
ADD ${LIBOSJ_URL} /tmp/libosj.tar.gz
RUN mkdir -p /home/shiny/dist && \
    tar -xzf /tmp/libosj.tar.gz -C /home/shiny/dist && \
    rm /tmp/libosj.tar.gz

# Copy the Shiny app code
COPY OsteoSort /srv/shiny-server/OsteoSort

# Set library path so Julia runtime libs can be found
ENV LD_LIBRARY_PATH="/home/shiny/dist/libosj/lib:/home/shiny/dist/libosj/lib/julia"

# Change ownership
RUN chown -R shiny /srv/shiny-server/OsteoSort && \
    chown -R shiny /home/shiny

# Expose the application port
EXPOSE 3838

# Start shiny-server
CMD ["shiny-server"]
