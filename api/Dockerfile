# API service: FastAPI generic layer over the database's api schema (D16, D22).
# Two targets:
#   runtime  the deployed image (used by the api service)
#   test     runtime + pytest + tests (used by the api-test service only)

FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir . \
 && useradd --system --no-create-home api
USER api
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]

FROM runtime AS test
USER root
RUN pip install --no-cache-dir ".[test]"
COPY tests ./tests
USER api
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"]
