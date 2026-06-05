#!/bin/bash
set -e

yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker

docker run -d \
  --name postgres \
  --restart unless-stopped \
  -e POSTGRES_DB=iotdb \
  -e POSTGRES_USER=iotuser \
  -e POSTGRES_PASSWORD=${postgres_password} \
  -p 5432:5432 \
  postgres:15-alpine

sleep 30

docker exec postgres psql -U iotuser -d iotdb -c "
  CREATE TABLE IF NOT EXISTS sensor_events (
    id          SERIAL PRIMARY KEY,
    device_id   VARCHAR(255) NOT NULL,
    sensor_type VARCHAR(100) NOT NULL,
    value       DECIMAL(10, 2) NOT NULL,
    timestamp   TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS idx_device_id ON sensor_events(device_id);
  CREATE INDEX IF NOT EXISTS idx_timestamp  ON sensor_events(timestamp);
"
