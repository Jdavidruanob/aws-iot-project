# Especificación Técnica — IoT SaaS Platform on AWS

> Documentación técnica detallada del proyecto. Para instrucciones de uso ver [README.md](README.md).

**Curso:** Sistemas de IoT — Universidad Javeriana Cali  
**Autor:** Juan David Ruano Bedoya  
**Región AWS:** `us-east-1` (AWS Learner Lab)

---

## Índice

1. [Arquitectura General](#1-arquitectura-general)
2. [Flujo de Datos](#2-flujo-de-datos)
3. [Stack Tecnológico](#3-stack-tecnológico)
4. [Componentes en Detalle](#4-componentes-en-detalle)
5. [Infraestructura Terraform](#5-infraestructura-terraform)
6. [Convenciones y Decisiones de Diseño](#6-convenciones-y-decisiones-de-diseño)
7. [Problemas Conocidos y Soluciones](#7-problemas-conocidos-y-soluciones)

---

## 1. Arquitectura General

```
┌─────────────────────────────── LOCAL ───────────────────────────────────┐
│                                                                          │
│  ┌──────────────┐   MQTT     ┌───────────────────────────────────────┐  │
│  │ sensor-      │  (1883)    │          edge-gateway                 │  │
│  │ temp-01      │───────────▶│          (Mosquitto 2.0)              │  │
│  │ humidity-01  │            │                                       │  │
│  │ co2-01       │            │  Broker MQTT local → Bridge mTLS      │  │
│  └──────────────┘            │  hacia AWS IoT Core (puerto 8883)     │  │
│                              └──────────────┬────────────────────────┘  │
└─────────────────────────────────────────────│───────────────────────────┘
                                              │ MQTT over TLS (X.509)
                                              ▼
┌──────────────────────────────── AWS (us-east-1) ────────────────────────┐
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                      AWS IoT Core                                  │  │
│  │   Topic: lab/sensors/data                                         │  │
│  │                                                                    │  │
│  │   Regla 1: SELECT * → DynamoDB (SensorData-lab)                   │  │
│  │   Regla 2: SELECT * → S3 (data/year=.../month=.../day=.../)       │  │
│  │   Regla 3: WHERE sensor_type='temperature' AND value > 35         │  │
│  │            → Lambda iot-alert                                     │  │
│  └──────────┬──────────────────┬───────────────────┬─────────────────┘  │
│             │                  │                   │                      │
│             ▼                  ▼                   ▼                      │
│  ┌──────────────────┐ ┌───────────────┐ ┌──────────────────────────┐    │
│  │  DynamoDB        │ │  S3 Bucket    │ │  Lambda: iot-alert        │    │
│  │  SensorData-lab  │ │  (cold data)  │ │  (sin VPC)               │    │
│  │  hash: device_id │ │  JSON por     │ └──────────┬───────────────┘    │
│  │  range: timestamp│ │  fecha        │             │                      │
│  └──────────────────┘ └──────┬────────┘             ▼                      │
│                               │          ┌───────────────────────┐         │
│                               │          │  SQS Queue            │         │
│                               │          │  iot-saas-alerts-lab  │         │
│                               │          └──────────┬────────────┘         │
│                               │                     │ Event Source Mapping  │
│                               ▼                     ▼                       │
│  ┌──────────────────────────────────────┐ ┌─────────────────────────────┐  │
│  │  Lambda: iot-s3-to-postgres (en VPC) │ │  Lambda: iot-cloudwatch-    │  │
│  │  S3 ObjectCreated → lee JSON →       │ │  logger                     │  │
│  │  INSERT en PostgreSQL                │ │  SQS → logger.warning()     │  │
│  │  + auto-registra sensor en DynamoDB  │ └──────────┬──────────────────┘  │
│  └──────────────┬───────────────────────┘            │                      │
│                 │                                     ▼                      │
│                 ▼                        ┌────────────────────────────────┐  │
│  ┌───────────────────────────┐          │  CloudWatch Logs               │  │
│  │  EC2 t3.micro (us-east-1a)│          │  /aws/lambda/iot-cw-logger     │  │
│  │  PostgreSQL 15 (Docker)   │          │  [WARNING] ALERTA CRITICA ...  │  │
│  └───────────────────────────┘          └────────────────────────────────┘  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  VPC Default                                                         │    │
│  │  ALB (puerto 80) → ECS Fargate (FastAPI, puerto 8000)               │    │
│  │      ├── GET /current  /recent  → DynamoDB                          │    │
│  │      ├── GET /history            → PostgreSQL                        │    │
│  │      └── GET /sensors  POST /sensors → DynamoDB registry            │    │
│  │  VPC Gateway Endpoint S3 — Lambda accede a S3 sin salir a internet  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Flujo de Datos

### 2.1 Flujo normal (cada 5–10 segundos por sensor)

```
sensor_simulator.py
  └─ genera JSON: {device_id, sensor_type, value, timestamp}
  └─ publica en topic "lab/sensors/data" vía MQTT (QoS 1) al broker local

Mosquitto (edge_gateway)
  └─ recibe en listener local (puerto 1883)
  └─ reenvía a AWS IoT Core (mTLS, puerto 8883)

AWS IoT Core (topic: lab/sensors/data)
  ├─ Regla 1 → DynamoDB: PUT item en SensorData-lab
  │     Clave: device_id (hash) + timestamp (range)
  └─ Regla 2 → S3: escribe JSON
        Key: data/year=YYYY/month=MM/day=DD/<topic>_<uuid>.json

S3 (s3:ObjectCreated) → Lambda iot-s3-to-postgres
  └─ decodifica key con unquote_plus (el "=" en "year=2026" viene como "%3D")
  └─ lee JSON con s3.get_object()
  └─ auto-registra sensor en SensorsRegistry-lab (ConditionExpression: solo si no existe)
  └─ INSERT en PostgreSQL: (device_id, sensor_type, value, timestamp)
```

### 2.2 Flujo de alerta (temperatura > 35 °C)

```
AWS IoT Core Regla 3 (WHERE sensor_type='temperature' AND value > 35)
  └─ invoca Lambda iot-alert (síncronamente)

Lambda iot-alert
  └─ formatea: {alert_type: "HIGH_TEMPERATURE", device_id, value, ...}
  └─ sqs.send_message() → cola iot-saas-alerts-lab

SQS (Event Source Mapping, batch_size=1)
  └─ entrega mensajes a Lambda iot-cloudwatch-logger

Lambda iot-cloudwatch-logger
  └─ logger.warning("ALERTA DE URGENCIA | device=... | value=...")
  └─ CloudWatch Logs: /aws/lambda/iot-cloudwatch-logger
```

### 2.3 Consulta de datos vía API

```
Cliente HTTP → ALB (puerto 80) → ECS Task FastAPI (puerto 8000)

GET /sensor/{id}/current  → DynamoDB.query(ScanIndexForward=False, Limit=1)
GET /sensor/{id}/recent   → DynamoDB.query(ScanIndexForward=False, Limit=10)
GET /sensor/{id}/history  → PostgreSQL: SELECT * WHERE device_id=%s ORDER BY timestamp DESC
GET /sensors              → DynamoDB.scan() en SensorsRegistry-lab
POST /sensors             → DynamoDB.put_item() en SensorsRegistry-lab
```

---

## 3. Stack Tecnológico

| Capa | Tecnología | Justificación |
|------|-----------|--------------|
| Sensores | Python 3.12 + paho-mqtt | Librería MQTT estándar para Python |
| Broker local | Eclipse Mosquitto 2.0 | Bridge MQTT→AWS IoT Core con mTLS |
| IaC | Terraform ~5.0 | Infraestructura reproducible en 8 módulos |
| IoT Core | AWS IoT Core (Rules Engine SQL) | Enrutamiento declarativo sin código |
| Hot data | DynamoDB (On-Demand) | Lecturas rápidas del último/reciente dato |
| Cold data | S3 (Standard) | Almacenamiento barato, particionado por fecha |
| Histórico | PostgreSQL 15 en Docker sobre EC2 t3.micro | Consultas SQL, rango de fechas |
| Driver Postgres | pg8000 1.31.2 | Puro Python — no requiere compilación en Lambda |
| Cola alertas | SQS Standard | Desacoplamiento entre detector y logger |
| API | FastAPI + uvicorn | Async, tipado, Swagger UI en /docs |
| Imagen API | Docker Hub | Sin necesidad de ECR en Learner Lab |
| Deploy API | ECS Fargate + ALB | Serverless de contenedores |
| Monitoreo | CloudWatch Logs | Integración automática con Lambda |

---

## 4. Componentes en Detalle

### 4.1 Simuladores de Sensores

**Archivo:** `python_device/sensor_simulator.py`

Un solo script parametrizado por variables de entorno:

| Variable | Descripción |
|----------|-------------|
| `MQTT_HOST` | Hostname del broker (`mosquitto` en Docker Compose) |
| `CLIENT_ID` | Identificador único del sensor |
| `SENSOR_TYPE` | `temperature`, `humidity`, o `co2` |
| `INTERVAL` | Segundos entre publicaciones |
| `PYTHONUNBUFFERED` | `1` para ver logs en tiempo real en Docker |

Rangos simulados:
- `temperature`: 20–40 °C (cruza 35 °C frecuentemente → dispara alertas)
- `humidity`: 40–80 % RH
- `co2`: 400–1500 ppm

### 4.2 Edge Gateway (Mosquitto)

Mosquitto actúa como broker local **y** bridge hacia AWS IoT Core:
- **Listener local:** puerto 1883, `allow_anonymous true`
- **Bridge:** reenvía `lab/sensors/data` a IoT Core por puerto 8883 con mTLS

`mosquitto.conf` y los certificados en `edge_gateway/certs/` son **generados automáticamente por Terraform** (recursos `local_file` en el módulo `iot`). No se commitean (`.gitignore`).

### 4.3 AWS IoT Core — Reglas

El Rules Engine evalúa una consulta SQL por cada mensaje recibido. Las reglas son independientes — un mensaje puede cumplir varias simultáneamente.

**Regla 1** — `SELECT * FROM 'lab/sensors/data'` → DynamoDB `put_item`  
**Regla 2** — `SELECT * FROM 'lab/sensors/data'` → S3 con key particionado por fecha  
**Regla 3** — `SELECT * ... WHERE sensor_type = 'temperature' AND value > 35` → Lambda `iot-alert`

### 4.4 DynamoDB

**`SensorData-lab`:**
```
hash_key:  device_id  (String)
range_key: timestamp  (String ISO 8601 UTC)
```
El Sort Key permite que múltiples eventos del mismo sensor coexistan. Habilita:
- `/current`: `query(ScanIndexForward=False, Limit=1)`
- `/recent`: `query(ScanIndexForward=False, Limit=10)`

**`SensorsRegistry-lab`:** `hash_key: device_id` — catálogo de sensores. Se puebla automáticamente cuando la Lambda `s3_to_postgres` procesa el primer archivo de cada sensor.

### 4.5 S3 (cold data)

Archivos particionados con convención Hive/Athena — compatible con AWS Athena para queries SQL directas sobre S3:

```
s3://lab-iot-saas-sensor-data-<hash>/
└── data/
    └── year=2026/
        └── month=06/
            └── day=05/
                └── data_<uuid>.json
```

### 4.6 Lambda: s3_to_postgres

**Trigger:** `s3:ObjectCreated:*` con prefijo `data/`  
**VPC:** sí (necesita acceder a PostgreSQL por IP privada)

Flujo:
1. Decodifica el key con `unquote_plus` — S3 URL-encodea el `=` en `year=2026` como `%3D`
2. Lee el JSON con `s3.get_object()`
3. Auto-registra el sensor en `SensorsRegistry-lab` con `ConditionExpression="attribute_not_exists(device_id)"` (idempotente)
4. `INSERT INTO sensor_events` en PostgreSQL con `pg8000`

**Empaquetado:** `pg8000` y dependencias se instalan con `pip install -t lambda/s3_to_postgres/` e incluyen en el ZIP junto al `handler.py`. El módulo Terraform usa `archive_file` para generar el ZIP automáticamente.

### 4.7 Lambda: alert

**Trigger:** IoT Core Regla 3 (invocación directa)  
**Sin VPC** — SQS es endpoint público de AWS

Recibe el mensaje MQTT como `event`, lo reformatea y llama a `sqs.send_message()`.

### 4.8 Lambda: cloudwatch_logger

**Trigger:** SQS Event Source Mapping (`batch_size=1`)  
**Sin VPC**

AWS hace polling automático de la cola. Procesa mensajes con `logger.warning()` — nivel WARNING para filtrar fácilmente en CloudWatch.

**¿Por qué dos Lambdas?** SQS desacopla el detector del logger. Si el logger falla, el mensaje queda en cola y se reintenta. Permite añadir más consumidores (email, SMS) sin tocar la Lambda de IoT Core.

### 4.9 API REST (FastAPI en ECS Fargate)

**Archivo:** `api/main.py`

| Endpoint | Fuente de datos |
|----------|----------------|
| `GET /health` | — |
| `GET /sensors` | DynamoDB SensorsRegistry-lab |
| `POST /sensors` | DynamoDB SensorsRegistry-lab |
| `GET /sensor/{id}/current` | DynamoDB SensorData-lab |
| `GET /sensor/{id}/recent` | DynamoDB SensorData-lab |
| `GET /sensor/{id}/history` | PostgreSQL sensor_events |

La API corre como contenedor en ECS Fargate detrás de un ALB. El health check `GET /health` es llamado por el ALB cada 30 segundos — si falla 3 veces, el Service reemplaza la tarea automáticamente.

### 4.10 PostgreSQL en EC2

EC2 `t3.micro` en `us-east-1a` con PostgreSQL 15 corriendo en Docker. El esquema se crea vía UserData al iniciar la instancia (`terraform/modules/postgres/user_data.sh`):

```sql
CREATE TABLE sensor_events (
  id          SERIAL PRIMARY KEY,
  device_id   VARCHAR(255) NOT NULL,
  sensor_type VARCHAR(100) NOT NULL,
  value       DECIMAL(10, 2) NOT NULL,
  timestamp   TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_device_id ON sensor_events(device_id);
CREATE INDEX idx_timestamp  ON sensor_events(timestamp);
```

Solo acepta conexiones al puerto 5432 desde los Security Groups de Lambda y ECS.

---

## 5. Infraestructura Terraform

### 5.1 Módulos

```
terraform/main.tf  ← orquesta los 8 módulos
         │
         ├── module.storage    → S3 bucket (sufijo random para unicidad global)
         ├── module.database   → DynamoDB: SensorData-lab + SensorsRegistry-lab
         ├── module.networking → 4 Security Groups + VPC Gateway Endpoint S3
         ├── module.postgres   → EC2 t3.micro + UserData
         ├── module.messaging  → Cola SQS (solo la cola)
         ├── module.lambda     → 3 Lambdas + S3 trigger + ESM SQS→Lambda
         ├── module.iot        → Thing + certificados + 3 reglas + archivos locales
         └── module.compute    → ECS Cluster + Task Definition + ALB + Service
```

### 5.2 Data sources (data.tf)

El Learner Lab no permite crear roles IAM — Terraform referencia el predefinido:

```hcl
data "aws_iam_role" "lab_role" { name = "LabRole" }
```

Otros data sources clave:
- `aws_vpc.default` / `aws_subnets.default` → VPC y subnets predeterminadas
- `aws_subnet.postgres_az` → subnet específica en `us-east-1a`
- `aws_iot_endpoint.iot_endpoint` → endpoint único de IoT Core (inyectado en `mosquitto.conf`)
- `data.http.root_ca` → Amazon Root CA descargada en tiempo de apply
- `aws_ami.amazon_linux_2023` → AMI más reciente para EC2

### 5.3 Dependencia circular resuelta

`lambda` necesita el ARN de la cola SQS (de `messaging`). Si `messaging` también referenciara la Lambda habría un ciclo. Solución: el `aws_lambda_event_source_mapping` vive en el módulo `lambda`, no en `messaging`.

### 5.4 Networking

```
Internet → ALB SG (:80 abierto)
ALB     → ECS Tasks SG (:8000 solo desde ALB)
ECS     → Postgres SG (:5432 solo desde ECS y Lambda)
Lambda  → Postgres SG (:5432 solo desde Lambda y ECS)
Lambda  → S3 vía VPC Gateway Endpoint (gratuito, sin NAT)
```

---

## 6. Convenciones y Decisiones de Diseño

### Nomenclatura AWS
- Patrón: `{project_name}-{recurso}-{environment}` → e.g. `iot-saas-alerts-lab`
- Tablas DynamoDB: `SensorData-lab`, `SensorsRegistry-lab` (PascalCase del lab base)
- Lambdas: `iot-{función}` sin sufijo de entorno

### Terraform
- Un módulo por servicio AWS (alta cohesión, bajo acoplamiento)
- Outputs de un módulo son inputs del siguiente (inyección explícita en `main.tf`)
- Todas las variables tienen `default` → no se necesita `terraform.tfvars`
- Data sources para todo lo que el Learner Lab provee

### Python
- Timestamp: ISO 8601 UTC con `datetime.now(timezone.utc).isoformat()`
- Driver PostgreSQL: `pg8000` en lugar de `psycopg2` (puro Python, sin compilación)
- Credenciales por variables de entorno, nunca hardcodeadas
- `logger.warning()` en lugar de `print()` para filtrar por nivel en CloudWatch
- `PYTHONUNBUFFERED=1` en contenedores Docker para logs en tiempo real

### Empaquetado de Lambda
Las dependencias se instalan en el mismo directorio del handler con `pip install -t .` para que el ZIP resultante incluya todo. Alternativas descartadas:
- Lambda Layers: útil si múltiples Lambdas comparten deps — aquí solo una usa pg8000
- Container Image: útil para deps con C nativo — pg8000 es puro Python

---

## 7. Problemas Conocidos y Soluciones

### S3 URL-encodea los keys en eventos

**Síntoma:** Lambda `iot-s3-to-postgres` fallaba con `NoSuchKey` aunque el archivo existía.

**Causa:** S3 URL-encodea el campo `object.key` en los eventos. El `=` en `year=2026` se transforma en `%3D`.

**Solución:**
```python
from urllib.parse import unquote_plus
key = unquote_plus(record["s3"]["object"]["key"])
```

### t3.micro no disponible en us-east-1e

**Síntoma:** `terraform apply` fallaba con error de AZ no soportada.

**Solución:** Data source con filtro explícito de AZ:
```hcl
data "aws_subnet" "postgres_az" {
  filter { name = "availabilityZone"; values = ["us-east-1a"] }
}
```

### Credenciales temporales del Learner Lab

Las credenciales expiran cada ~4 horas. Al iniciar nueva sesión: re-exportar credenciales antes de entrar al contenedor de desarrollo. El `terraform.tfstate` persiste entre sesiones.

### ENIs de Lambda en VPC

Al destruir la infraestructura, el Security Group de Lambda tarda 5–10 minutos en eliminarse porque AWS debe liberar primero las Elastic Network Interfaces (ENIs) que Lambda creó al correr en VPC. Es comportamiento normal de AWS — no interrumpir el destroy.
