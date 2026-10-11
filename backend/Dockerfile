FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY backend /app/backend

EXPOSE 5000
CMD ["uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "5000"]
