FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq bash \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Source code is mounted at runtime via docker-compose volumes
CMD ["bash"]
