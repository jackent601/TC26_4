# Database image, used by two services:
#   db       PostgreSQL 16 with pgTAP (database unit tests)
#   migrate  runs dbmate, then db/setup/roles.sql with psql
FROM postgres:16
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgtap \
 && rm -rf /var/lib/apt/lists/*
ADD --chmod=755 https://github.com/amacneil/dbmate/releases/download/v2.38.1/dbmate-linux-${TARGETARCH} /usr/local/bin/dbmate
