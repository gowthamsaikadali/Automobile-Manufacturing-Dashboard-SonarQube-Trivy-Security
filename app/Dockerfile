# ---- build stage ----
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
# --prefix installs to a fixed path, independent of $HOME or which user
# runs the container -- avoids the --user/$HOME mismatch that broke the
# original build (packages installed under one user's home, container ran
# as a different user with a different home, ModuleNotFoundError at runtime).
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- final stage ----
FROM python:3.12-slim
LABEL maintainer="auto-unit-devsecops"

# Create a non-root user -- containers must never run as root (Trivy/CIS check)
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app
# /usr/local is on Python's default sys.path regardless of which user runs
# the process -- no $HOME dependency, unlike the old --user approach.
COPY --from=builder /install /usr/local
COPY . .

RUN chown -R appuser:appuser /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/healthz')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "60", "app:app"]
