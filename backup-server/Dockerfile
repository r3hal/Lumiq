FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt && useradd --system --uid 10001 focal
COPY focal_backup ./focal_backup
RUN mkdir /data && chown focal:focal /data
USER focal
ENV FOCAL_DATA=/data
EXPOSE 8000
CMD ["uvicorn", "focal_backup.app:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-access-log", "--log-level", "error"]
