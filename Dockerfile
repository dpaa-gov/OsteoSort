# syntax=docker/dockerfile:1
# What Atlas builds. Nothing is compiled here: the Julia side comes from the
# release named below, so that release must already have its asset attached.

FROM debian:bookworm-slim AS bundle

# Bump with each release
ARG OSTEOSORT_VERSION=v2.0.0-alpha.3
# Or a local path, to try a bundle built on this machine
ARG BUNDLE=https://github.com/dpaa-gov/OsteoSort/releases/download/${OSTEOSORT_VERSION}/osteosort-linux-x86_64.tar.gz

# A URL arrives as the archive; a local archive arrives already unpacked
ADD ${BUNDLE} /tmp/bundle/
RUN mkdir -p /opt && \
    if [ -d /tmp/bundle/osteosort ]; then mv /tmp/bundle/osteosort /opt/osteosort; \
    else tar -xzf /tmp/bundle/*.tar.gz -C /opt; fi

FROM debian:bookworm-slim

RUN useradd --uid 10001 --create-home osteosort
COPY --from=bundle /opt/osteosort /opt/osteosort

# Read at run time, at the paths the program was compiled with
WORKDIR /app
COPY server/config /app/server/config
COPY web /app/web
COPY VERSION /app/VERSION

# Two worker threads for analyses, one interactive thread for requests
ENV JULIA_NUM_THREADS=2,1 \
    PORT=3838

USER osteosort
EXPOSE 3838
CMD ["/opt/osteosort/bin/osteosort"]
