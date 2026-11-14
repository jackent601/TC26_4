# Test-only image (decision I2). Never used by the deployed services.
# PostgreSQL 16 + pgTAP + pg_prove + dbmate. Each run starts a throwaway database
# inside the container, applies every migration, runs db/tests, checks the
# migrations roll back and re-apply, and exits with pass (0) or fail (1).
FROM postgres:16
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgtap libtap-parser-sourcehandler-pgtap-perl \
 && rm -rf /var/lib/apt/lists/*
ADD --chmod=755 https://github.com/amacneil/dbmate/releases/download/v2.38.1/dbmate-linux-${TARGETARCH} /usr/local/bin/dbmate
COPY --chmod=755 run-tests.sh /usr/local/bin/run-tests.sh
ENTRYPOINT ["/usr/local/bin/run-tests.sh"]
