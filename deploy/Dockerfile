# Build from the backend/ directory: docker build -f deploy/Dockerfile backend
# PYTHON_IMAGE can point to a registry mirror when Docker Hub rate-limits.
ARG PYTHON_IMAGE=python:3.13-slim

FROM ${PYTHON_IMAGE} AS builder
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
RUN pip install --no-cache-dir uv==0.8.17
WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --locked --no-dev --no-install-project --no-editable
COPY src ./src
RUN uv sync --locked --no-dev --no-editable

FROM ${PYTHON_IMAGE} AS runtime
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
    && mkdir -p /data/files /monitor && chown app /data/files /monitor
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER app
EXPOSE 8000
# No uvicorn access log: RequestIdMiddleware logs requests without query strings.
CMD ["uvicorn", "tasker.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
