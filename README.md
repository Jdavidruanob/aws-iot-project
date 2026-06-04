# Plataforma IoT SaaS en AWS — Proyecto Final

> **Curso:** Sistemas de IoT — Universidad Javeriana Cali  
> **Autor:** Juan David Ruano Bedoya (jdavidruanob)  
> **Región AWS:** `us-east-1` (AWS Learner Lab)  
> **Infraestructura:** Terraform 8 módulos | Python 3.12 | Docker

---

## Índice

1. [Contexto del Proyecto](#1-contexto-del-proyecto)
2. [Arquitectura General](#2-arquitectura-general)
3. [Flujo de Datos](#3-flujo-de-datos)
4. [Stack Tecnológico](#4-stack-tecnológico)
5. [Estructura del Repositorio](#5-estructura-del-repositorio)
6. [Componentes en Detalle](#6-componentes-en-detalle)
7. [Infraestructura Terraform](#7-infraestructura-terraform)
8. [Guía de Despliegue](#8-guía-de-despliegue)
9. [Verificación del Sistema](#9-verificación-del-sistema)
10. [Convenciones y Decisiones de Diseño](#10-convenciones-y-decisiones-de-diseño)
11. [Problemas Conocidos y Soluciones](#11-problemas-conocidos-y-soluciones)

---

## 1. Contexto del Proyecto

Este proyecto extiende el laboratorio base del curso (`7_iot_s3_dynamo_athena`) para construir una plataforma SaaS de IoT completa sobre AWS. El laboratorio base ya tenía: sensores Python → Mosquitto → AWS IoT Core → DynamoDB + S3. La extensión agrega 7 hitos:

| # | Hito | Descripción |
|---|------|-------------|
| 1 | PostgreSQL en EC2 | Base de datos relacional para histórico de eventos |
| 2 | Lambda S3 Trigger | Lambda que se activa cuando IoT Core escribe un archivo en S3 |
| 3 | Lambda S3→PostgreSQL | La misma Lambda lee el JSON y lo inserta en PostgreSQL |
| 4 | API REST FastAPI | 5 endpoints para consultar datos de sensores |
| 5 | Deploy API en ECS Fargate | La API corre en contenedor gestionado por AWS con ALB |
| 6 | Sistema de Alertas | IoT Rule → Lambda → SQS → Lambda → CloudWatch Logs |
| 7 | Tercer sensor (CO2) | Sensor adicional a temperatura y humedad para sustentación |

El ambiente AWS es un **Learner Lab** con restricciones: se usa el rol `LabRole` predefinido en lugar de crear roles IAM personalizados. Las credenciales son temporales y cambian cada sesión.

---

## 2. Arquitectura General

```
┌─────────────────────────────── LOCAL ───────────────────────────────────┐
│                                                                          │
│  ┌──────────────┐   MQTT     ┌───────────────────────────────────────┐  │
│  │ sensor-      │  (1883)    │          edge-gateway                 │  │
│  │ temp-01      │───────────▶│          (Mosquitto 2.0)              │  │
│  │ humidity-01  │            │                                       │  │
│  │ co2-01       │            │  Broker MQTT local → Bridge mTLS      │  │
│  └──────────────┘            │  hacia AWS IoT Core (puerto 8883)    │  │
│                              └──────────────┬────────────────────────┘  │
└─────────────────────────────────────────────│────────────────────────────┘
                                              │ MQTT over TLS (certificados X.509)
                                              ▼
┌──────────────────────────────── AWS (us-east-1) ────────────────────────┐
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                      AWS IoT Core                                  │  │
│  │   Topic: lab/sensors/data                                         │  │
│  │                                                                    │  │
│  │   Regla 1: SELECT * → DynamoDB (SensorData-lab)                   │  │
│  │   Regla 2: SELECT * → S3 (data/year=.../month=.../day=.../)       │  │
│  │   Regla 3: SELECT * WHERE sensor_type='temperature'               │  │
│  │            AND value > 35 → Lambda iot-alert                      │  │
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
│  └──────────────┬───────────────────────┘ └──────────┬──────────────────┘  │
│                 │                                     │                      │
│                 ▼                                     ▼                      │
│  ┌───────────────────────────┐          ┌────────────────────────────────┐  │
│  │  EC2 t3.micro (us-east-1a)│          │  CloudWatch Logs               │  │
│  │  PostgreSQL 15 (Docker)   │          │  /aws/lambda/iot-cw-logger     │  │
│  │  IP privada: VPC interna  │          │  [WARNING] ALERTA CRITICA ...  │  │
│  └───────────────────────────┘          └────────────────────────────────┘  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  VPC Default                                                         │    │
│  │                                                                       │    │
│  │  ┌────────────┐  :80    ┌──────────────────────────────────────────┐ │    │
│  │  │    ALB     │────────▶│  ECS Fargate Task (FastAPI)               │ │    │
│  │  │ (internet) │         │  jdavidruanob/iot-api:latest              │ │    │
│  │  └────────────┘         │  puerto 8000                              │ │    │
│  │                         └─────────────┬──────────────────────────────┘ │    │
│  │                                       │                                 │    │
│  │                       ┌───────────────┼─────────────┐                  │    │
│  │                       ▼               ▼             ▼                   │    │
│  │                  DynamoDB         DynamoDB      PostgreSQL               │    │
│  │                 (eventos)        (registry)    (histórico)               │    │
│  │                                                                          │    │
│  │  VPC Endpoint S3 (Gateway, gratuito) — Lambda-en-VPC accede a S3       │    │
│  │  sin salir a internet                                                    │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Flujo de Datos

### 3.1 Flujo normal (cada 5–10 segundos por sensor)

```
sensor_simulator.py
  └─ genera JSON: {device_id, sensor_type, value, timestamp}
  └─ publica en topic "lab/sensors/data" vía MQTT (QoS 1) al broker local

Mosquitto (edge_gateway)
  └─ recibe el mensaje en listener local (puerto 1883)
  └─ lo reenvía a AWS IoT Core (mTLS, puerto 8883)
     bridge_cafile:  AmazonRootCA1.pem  (verifica identidad de AWS)
     bridge_certfile/keyfile: certificados X.509 del Thing

AWS IoT Core (topic: lab/sensors/data)
  ├─ Regla 1 → DynamoDB: PUT item en SensorData-lab
  │     Clave: device_id (hash) + timestamp (range) → múltiples eventos por sensor
  └─ Regla 2 → S3: escribe archivo JSON
        Key: data/year=YYYY/month=MM/day=DD/<topic>_<uuid>.json

S3 (s3:ObjectCreated) → Lambda iot-s3-to-postgres
  └─ decodifica la key con unquote_plus (el "=" en "year=2026" se URL-encodea a "%3D")
  └─ lee el JSON con s3.get_object()
  └─ INSERT en PostgreSQL: (device_id, sensor_type, value, timestamp)
```

### 3.2 Flujo de alerta (cuando temperatura > 35 °C)

```
AWS IoT Core Regla 3 (WHERE sensor_type='temperature' AND value > 35)
  └─ invoca Lambda iot-alert (síncronamente)

Lambda iot-alert
  └─ formatea: {alert_type: "HIGH_TEMPERATURE", device_id, value, ...}
  └─ sqs.send_message() → cola iot-saas-alerts-lab

SQS (Event Source Mapping, batch_size=1, polling automático)
  └─ entrega mensajes a Lambda iot-cloudwatch-logger

Lambda iot-cloudwatch-logger
  └─ logger.warning("ALERTA DE URGENCIA | device=... | value=...")
  └─ CloudWatch Logs captura automáticamente todo lo que imprime Lambda
     log group: /aws/lambda/iot-cloudwatch-logger
```

### 3.3 Consulta de datos vía API

```
Cliente HTTP → ALB (puerto 80) → ECS Task FastAPI (puerto 8000)

GET /sensor/{id}/current  → DynamoDB.query(ScanIndexForward=False, Limit=1)
GET /sensor/{id}/recent   → DynamoDB.query(ScanIndexForward=False, Limit=10)
GET /sensor/{id}/history  → PostgreSQL: SELECT ... WHERE device_id=%s ORDER BY timestamp DESC
GET /sensors              → DynamoDB.scan() en SensorsRegistry-lab
POST /sensors             → DynamoDB.put_item() en SensorsRegistry-lab
```

---

## 4. Stack Tecnológico

| Capa | Tecnología | Justificación |
|------|-----------|--------------|
| Sensores | Python 3.12 + paho-mqtt | Librería MQTT estándar para Python |
| Broker local | Eclipse Mosquitto 2.0 | Bridge MQTT→AWS IoT Core con mTLS |
| IaC | Terraform ~5.0 (hashicorp/aws) | Infraestructura reproducible en módulos |
| IoT Core | AWS IoT Core (Rules Engine SQL) | Enrutamiento declarativo sin código |
| Hot data | DynamoDB (On-Demand) | Lecturas rápidas del último/reciente dato |
| Cold data | S3 (Standard) | Almacenamiento barato, particionado por fecha |
| Histórico | PostgreSQL 15 en Docker sobre EC2 t3.micro | Consultas SQL, rango de fechas, flexibilidad |
| Driver Postgres | pg8000 1.31.2 | Puro Python — no requiere compilación en Lambda |
| Cola alertas | SQS Standard | Desacoplamiento entre detector y logger |
| API | FastAPI + uvicorn | Async, tipado, Swagger UI automático en /docs |
| Imagen API | Docker Hub (jdavidruanob/iot-api:latest) | Sin necesidad de ECR en Learner Lab |
| Deploy API | ECS Fargate + ALB | Serverless de contenedores, sin gestionar EC2 |
| Monitoreo | CloudWatch Logs | Integración automática con Lambda |

---

## 5. Estructura del Repositorio

```
aws-iot-project/
│
├── Makefile                    ← Comandos principales (aws-up, local-up, push-api, etc.)
├── docker-compose.yml          ← 3 sensores + 1 gateway (simulación local)
├── test_deploy.sh              ← Script de verificación post-deploy (21 checks)
│
├── python_device/              ← Simulador de sensores
│   ├── Dockerfile
│   ├── requirements.txt        (paho-mqtt)
│   └── sensor_simulator.py     ← Un proceso = un sensor (configurado por env vars)
│
├── edge_gateway/               ← Broker MQTT local con bridge a AWS
│   ├── Dockerfile              (FROM eclipse-mosquitto:2.0)
│   ├── mosquitto.conf          ← GENERADO por Terraform (contiene endpoint AWS)
│   └── certs/                  ← GENERADOS por Terraform (.gitignore)
│       ├── certificate.pem.crt
│       ├── private.pem.key
│       ├── public.pem.key
│       └── AmazonRootCA1.pem
│
├── api/                        ← API REST FastAPI
│   ├── Dockerfile              (FROM python:3.12-slim)
│   ├── requirements.txt        (fastapi, uvicorn, boto3, pg8000)
│   └── main.py                 ← 5 endpoints REST
│
├── lambda/
│   ├── s3_to_postgres/
│   │   ├── handler.py          ← S3 ObjectCreated → PostgreSQL INSERT
│   │   └── requirements.txt    (pg8000==1.31.2)
│   ├── alert/
│   │   └── handler.py          ← IoT Rule 3 → SQS send_message
│   └── cloudwatch_logger/
│       └── handler.py          ← SQS → logger.warning() → CloudWatch
│
└── terraform/
    ├── main.tf                 ← Orquesta 8 módulos
    ├── variables.tf            ← Variables con defaults (no se necesita tfvars)
    ├── outputs.tf              ← api_url, iot_endpoint, bucket, tablas, etc.
    ├── data.tf                 ← Data sources: VPC, AMI, LabRole, IoT endpoint
    └── modules/
        ├── storage/            ← S3 bucket para cold data
        ├── database/           ← 2 tablas DynamoDB (eventos + registry)
        ├── networking/         ← Security groups + VPC Endpoint S3
        ├── postgres/           ← EC2 t3.micro + PostgreSQL en Docker (UserData)
        ├── iot/                ← Thing, certificados, 3 reglas, archivos locales
        ├── lambda/             ← 3 funciones + S3 trigger + ESM SQS→Lambda
        ├── messaging/          ← Cola SQS (solo la cola, sin referencias a Lambda)
        └── compute/            ← ECS Cluster + Task Definition + ALB + Service
```

---

## 6. Componentes en Detalle

### 6.1 Simuladores de Sensores (Python)

**Archivo:** `python_device/sensor_simulator.py`

Cada sensor es una instancia del mismo script, diferenciada por variables de entorno:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `MQTT_HOST` | IP/hostname del broker local | `mosquitto` (nombre del servicio en Docker Compose) |
| `CLIENT_ID` | Identificador único del sensor | `sensor-temp-01` |
| `SENSOR_TYPE` | Tipo de sensor | `temperature`, `humidity`, `co2` |
| `INTERVAL` | Segundos entre publicaciones | `5` |

**Formato del mensaje publicado:**
```json
{
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "value": 36.42,
  "timestamp": "2026-06-04T21:41:20.754114+00:00"
}
```

**Rangos de valores simulados:**
- `temperature`: 20.0–40.0 °C (cruza 35 °C frecuentemente → dispara alertas)
- `humidity`: 40.0–80.0 % RH
- `co2`: 400.0–1500.0 ppm (400 = aire exterior normal, >1000 = interior concurrido)

El sensor intenta reconectar automáticamente si el broker no está disponible.

### 6.2 Edge Gateway (Mosquitto)

**Archivos:** `edge_gateway/Dockerfile`, `edge_gateway/mosquitto.conf` (generado por Terraform)

Mosquitto actúa como broker MQTT local **y** como bridge hacia AWS IoT Core:

- **Listener local:** puerto 1883, sin autenticación (`allow_anonymous true`)
- **Bridge:** reenvía mensajes del topic `lab/sensors/data` a AWS IoT Core
  - Puerto 8883 (MQTT sobre TLS)
  - `bridge_insecure false` → verifica el certificado de AWS con `AmazonRootCA1.pem`
  - Autenticación mutua (mTLS): el bridge presenta su propio certificado X.509

`mosquitto.conf` y los certificados en `edge_gateway/certs/` son **generados automáticamente por Terraform** (recursos `local_file` en el módulo `iot`). No se commitean al repositorio (`.gitignore`).

### 6.3 AWS IoT Core — Reglas

**Archivo:** `terraform/modules/iot/main.tf`

El Rules Engine evalúa una consulta SQL sobre cada mensaje recibido:

**Regla 1 — DynamoDB (hot data):**
```sql
SELECT * FROM 'lab/sensors/data'
```
→ `dynamodbv2` action: PUT item en `SensorData-lab`

**Regla 2 — S3 (cold data):**
```sql
SELECT * FROM 'lab/sensors/data'
```
→ `s3` action: escribe JSON en el bucket
→ Key con particionado por fecha: `data/year=YYYY/month=MM/day=DD/<uuid>.json`

**Regla 3 — Alerta Lambda:**
```sql
SELECT * FROM 'lab/sensors/data'
WHERE sensor_type = 'temperature' AND value > 35
```
→ `lambda` action: invoca `iot-alert` con el mensaje MQTT como `event`

**IoT Thing y certificados:**
- Thing: `edge-gateway-01-lab`
- Terraform genera el certificado X.509 y lo escribe en `edge_gateway/certs/`
- La política IoT limita al Thing a conectarse solo con su `clientId` y publicar/suscribirse solo en `lab/sensors/*`

### 6.4 Almacenamiento: DynamoDB (hot data)

**Tabla `SensorData-lab`:**
```
hash_key:  device_id  (tipo String)
range_key: timestamp  (tipo String, ISO 8601 UTC)
```
El Sort Key (timestamp) es fundamental: permite que múltiples eventos del mismo sensor coexistan sin sobreescribirse. Sin él, cada `put_item` con el mismo `device_id` sobreescribiría el anterior.

Esto habilita:
- `/current`: `query(ScanIndexForward=False, Limit=1)` → el más reciente
- `/recent`: `query(ScanIndexForward=False, Limit=10)` → los 10 más recientes

**Tabla `SensorsRegistry-lab`:** solo `hash_key: device_id` (catálogo de sensores registrados).

### 6.5 Almacenamiento: S3 (cold data)

Los archivos siguen la convención de particionado de Hive/Athena:

```
s3://lab-iot-saas-sensor-data-<hash>/
└── data/
    └── year=2026/
        └── month=06/
            └── day=04/
                └── data_<uuid>.json
```

Esta estructura permite hacer queries SQL directamente sobre S3 con AWS Athena en el futuro.

### 6.6 Almacenamiento: PostgreSQL en EC2 (histórico)

**Archivo:** `terraform/modules/postgres/main.tf`

PostgreSQL corre dentro de un contenedor Docker en EC2 `t3.micro`. Se configura vía **UserData** al crear la instancia (se ejecuta una sola vez al iniciar):

1. Instala Docker (Amazon Linux 2023)
2. Levanta `postgres:15-alpine` en puerto 5432
3. Espera 30 s para que PostgreSQL arranque
4. Crea el esquema de la tabla `sensor_events`

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

**Red:** la instancia está en `us-east-1a` (única AZ con soporte `t3.micro` en este Learner Lab). Solo acepta conexiones al puerto 5432 desde los Security Groups de Lambda y ECS.

### 6.7 Lambda: s3_to_postgres

**Archivo:** `lambda/s3_to_postgres/handler.py`  
**Trigger:** `s3:ObjectCreated:*` con prefijo `data/`

**Flujo:**
1. Recibe evento S3 con `bucket` y `key`
2. **Decodifica la key con `unquote_plus`** — el `=` en `year=2026` se URL-encodea como `%3D` en los eventos S3
3. Lee el JSON del objeto con `s3.get_object()`
4. Conecta a PostgreSQL con `pg8000` y ejecuta `INSERT INTO sensor_events`

**Por qué pg8000 en vez de psycopg2:**  
`psycopg2` requiere compilar extensiones C al empaquetarse para Lambda. `pg8000` es puro Python: `pip install` simple, sin compilación, funciona directamente en el entorno Lambda.

**VPC:** Esta Lambda corre dentro de la VPC para conectarse a PostgreSQL por su IP privada. Usa el VPC Gateway Endpoint de S3 para acceder al bucket sin NAT (gratuito).

**Empaquetado:** Las dependencias (`pg8000` y sus sub-dependencias) se instalan con `pip install -t lambda/s3_to_postgres/` y se incluyen en el mismo ZIP que el handler.

### 6.8 Lambda: alert

**Archivo:** `lambda/alert/handler.py`  
**Trigger:** IoT Core Regla 3 (invocación directa, sin VPC)

El payload que recibe es el mensaje MQTT original. La Lambda lo reformatea y llama a `sqs.send_message()`:

```json
{
  "alert_type": "HIGH_TEMPERATURE",
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "value": 36.93,
  "timestamp": "2026-06-04T21:41:20.754114+00:00",
  "message": "ALERTA CRITICA: 36.93°C en sensor-temp-01"
}
```

### 6.9 Lambda: cloudwatch_logger

**Archivo:** `lambda/cloudwatch_logger/handler.py`  
**Trigger:** SQS Event Source Mapping (`batch_size=1`)

AWS hace polling automático a la cola. Cuando hay mensajes, los entrega al handler en `event["Records"]`. La Lambda itera los registros y llama a `logger.warning(...)`.

CloudWatch captura automáticamente todo lo que escribe Lambda. Los logs se ven en:

```bash
aws logs tail /aws/lambda/iot-cloudwatch-logger --since 1h
aws logs filter-log-events \
  --log-group-name /aws/lambda/iot-cloudwatch-logger \
  --filter-pattern "HIGH_TEMPERATURE"
```

**Nota sobre `logger.warning` vs `print`:** `logging.WARNING` permite filtrar por nivel en CloudWatch con `--filter-pattern "[WARNING]"`, y en un sistema real permitiría enrutar a alarmas de CloudWatch.

### 6.10 API REST (FastAPI en ECS Fargate)

**Archivo:** `api/main.py`  
**URL pública:** `http://<alb-dns>.us-east-1.elb.amazonaws.com`  
**Swagger UI:** `http://<alb-dns>/docs`

#### Endpoints

| Método | Ruta | Descripción | Fuente |
|--------|------|-------------|--------|
| `GET` | `/health` | Health check | — |
| `GET` | `/sensors` | Lista sensores registrados | DynamoDB: SensorsRegistry-lab |
| `POST` | `/sensors` | Registra un nuevo sensor | DynamoDB: SensorsRegistry-lab |
| `GET` | `/sensor/{id}/current` | Última lectura | DynamoDB: SensorData-lab |
| `GET` | `/sensor/{id}/recent` | Últimas 10 lecturas | DynamoDB: SensorData-lab |
| `GET` | `/sensor/{id}/history` | Histórico completo | PostgreSQL: sensor_events |

**Body para POST /sensors:**
```json
{
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "description": "Sensor de temperatura principal"
}
```

**Respuesta de /sensor/{id}/history:**
```json
{
  "device_id": "sensor-temp-01",
  "total": 231,
  "events": [
    {"device_id": "sensor-temp-01", "sensor_type": "temperature", "value": 30.8, "timestamp": "..."},
    ...
  ]
}
```

**Variables de entorno de la Task (ECS):**
```
AWS_REGION              = us-east-1
DYNAMODB_TABLE_NAME     = SensorData-lab
DYNAMODB_REGISTRY_TABLE = SensorsRegistry-lab
POSTGRES_HOST           = <IP privada del EC2>
POSTGRES_PORT           = 5432
POSTGRES_DB             = iotdb
POSTGRES_USER           = iotuser
POSTGRES_PASSWORD       = iotpassword123
```

### 6.11 Sistema de Alertas end-to-end

El pipeline demuestra el patrón **event-driven** completo:

```
IoT Core Regla 3 (SQL con WHERE threshold)
    │ invocación síncrona
    ▼
Lambda iot-alert
    │ sqs.send_message()
    ▼
Cola SQS iot-saas-alerts-lab
    │ polling automático (Event Source Mapping)
    ▼
Lambda iot-cloudwatch-logger
    │ logger.warning()
    ▼
CloudWatch Logs /aws/lambda/iot-cloudwatch-logger
```

**¿Por qué SQS en el medio?** Desacopla el detector del logger. Si el logger falla, el mensaje queda en la cola y se reintenta. Si se quisiera notificar a N sistemas (email, SMS, dashboard), todos pueden consumir de la misma cola o añadir más ESMs.

---

## 7. Infraestructura Terraform

### 7.1 Módulos y su responsabilidad

```
terraform/main.tf  ←  orquesta los 8 módulos
         │
         ├── module.storage    → S3 bucket (nombre con sufijo random para unicidad global)
         ├── module.database   → DynamoDB: SensorData-lab + SensorsRegistry-lab
         ├── module.networking → 4 Security Groups + VPC Gateway Endpoint S3
         ├── module.postgres   → EC2 t3.micro + UserData (Docker + PostgreSQL + schema)
         ├── module.messaging  → Cola SQS (SOLO la cola — sin referencias a Lambda)
         ├── module.lambda     → 3 Lambdas + S3 notification trigger + ESM SQS→Lambda
         ├── module.iot        → Thing + certificados + 3 reglas + archivos locales
         └── module.compute    → ECS Cluster + Task Definition + ALB + ECS Service
```

### 7.2 Variables (todas tienen default, no se necesita terraform.tfvars)

| Variable | Default | Descripción |
|----------|---------|-------------|
| `project_name` | `iot-saas` | Prefijo para todos los recursos AWS |
| `environment` | `lab` | Sufijo del entorno |
| `alert_threshold` | `35` | Temperatura °C que dispara alertas (Regla 3) |
| `postgres_password` | `iotpassword123` | Contraseña PostgreSQL (marked sensitive) |
| `api_image` | `jdavidruanob/iot-api:latest` | Imagen Docker Hub de la API |

### 7.3 Data sources (terraform/data.tf)

El Learner Lab no permite crear roles IAM. Terraform referencia el rol predefinido:

```hcl
data "aws_iam_role" "lab_role" { name = "LabRole" }
```

Otros data sources clave:
- `aws_vpc.default` / `aws_subnets.default` → VPC y subnets predeterminadas
- `aws_subnet.postgres_az` → subnet específica en `us-east-1a` (única AZ con soporte `t3.micro`)
- `aws_iot_endpoint.iot_endpoint` → endpoint único de IoT Core (inyectado en `mosquitto.conf`)
- `data.http.root_ca` → descarga Amazon Root CA desde `amazontrust.com`
- `aws_ami.amazon_linux_2023` → AMI más reciente para EC2

### 7.4 Dependencia circular resuelta

`messaging` y `lambda` tenían riesgo de ciclo:
- `lambda` necesita `sqs_queue_arn` (de messaging) para el Event Source Mapping
- Si `messaging` referenciara el ARN de la Lambda, habría un ciclo

**Solución:** El `aws_lambda_event_source_mapping` vive en el módulo `lambda`, no en `messaging`. El módulo `messaging` solo crea la cola SQS sin ninguna referencia a Lambda.

### 7.5 Networking (Security Groups)

```
Internet (0.0.0.0/0)
    │ :80
    ▼
ALB SG (iot-alb-sg)
    │ :80 → :8000
    ▼
ECS Tasks SG (iot-ecs-tasks-sg)   ─── :5432 ──▶  Postgres SG (iot-postgres-sg)
                                                         ▲
Lambda SG (iot-lambda-sg) ─────────── :5432 ────────────┘
    │
    └─ egress total → S3 via VPC Gateway Endpoint (gratuito, sin NAT)
```

### 7.6 Outputs post-deploy

```bash
cd terraform && terraform output
# api_url              = "http://iot-saas-alb-lab-XXXXXXXX.us-east-1.elb.amazonaws.com"
# iot_endpoint         = "aXXXXXX-ats.iot.us-east-1.amazonaws.com"
# sensor_bucket_name   = "lab-iot-saas-sensor-data-XXXXXXXX"
# dynamodb_events_table    = "SensorData-lab"
# dynamodb_registry_table  = "SensorsRegistry-lab"
# postgres_private_ip  = "172.31.X.X"
```

---

## 8. Guía de Despliegue

### Prerrequisitos

- Docker instalado con imagen `iot-dev` disponible (contenedor de desarrollo del curso)
- Cuenta activa en Docker Hub (para publicar la imagen de la API)
- Credenciales AWS del Learner Lab (se renuevan cada sesión)

### Paso 1 — Publicar la imagen de la API

Solo es necesario si se modifica `api/main.py` o `api/Dockerfile`.

```bash
docker login
make push-api
# Equivale a: docker build -t jdavidruanob/iot-api:latest ./api/ && docker push ...
```

### Paso 2 — Desplegar infraestructura en AWS

```bash
# Exportar credenciales del Learner Lab:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
export AWS_DEFAULT_REGION=us-east-1

# Iniciar el contenedor de desarrollo:
docker run --rm -it \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN -e AWS_DEFAULT_REGION \
  -v $(pwd):/workspace:Z \
  iot-dev bash

# Dentro del contenedor:
cd /workspace
make aws-up
# Equivale a: pip install pg8000 -t lambda/s3_to_postgres/ + terraform init + terraform apply
```

> **Nota Fedora/SELinux:** el flag `:Z` en el volumen es obligatorio para que SELinux permita que el contenedor lea/escriba en el directorio del host.

`terraform apply` crea ~40 recursos en ~5 minutos. Al finalizar imprime los outputs con la URL de la API y demás valores.

### Paso 3 — Levantar sensores locales

```bash
# En la máquina del desarrollador (fuera del contenedor dev):
make local-up
# Equivale a: docker compose up -d --build

make logs    # ver flujo de datos en tiempo real
```

Esto levanta 4 contenedores:
- `edge-gateway-mosquitto` — broker MQTT con bridge a AWS (usa certs generados por Terraform)
- `sensor-temp-01` — temperatura, cada 5 s
- `sensor-humidity-01` — humedad, cada 7 s
- `sensor-co2-01` — CO2, cada 10 s

### Paso 4 — Registrar sensores en el catálogo

```bash
API_URL=$(cd terraform && terraform output -raw api_url)

curl -X POST "$API_URL/sensors" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"sensor-temp-01","sensor_type":"temperature","description":"Sensor de temperatura principal"}'

curl -X POST "$API_URL/sensors" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"sensor-co2-01","sensor_type":"co2","description":"Sensor de CO2"}'
```

### Paso 5 — Destruir infraestructura

```bash
# Dentro del contenedor de desarrollo:
make aws-down
# Equivale a: terraform destroy -auto-approve
```

### Makefile — referencia completa

| Comando | Descripción |
|---------|-------------|
| `make aws-up` | Instala deps de Lambda + `terraform apply` |
| `make aws-down` | `terraform destroy` |
| `make local-up` | `docker compose up -d --build` |
| `make local-down` | `docker compose down` |
| `make logs` | `docker compose logs -f` |
| `make push-api` | Build + push de la imagen a Docker Hub |
| `make build-lambdas` | `pip install pg8000 -t lambda/s3_to_postgres/` |
| `make clean` | Destruye todo (AWS + local) y limpia archivos generados |

---

## 9. Verificación del Sistema

El script `test_deploy.sh` verifica el sistema completo automáticamente:

```bash
docker run --rm \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_SESSION_TOKEN=... \
  -e AWS_DEFAULT_REGION=us-east-1 \
  -v $(pwd):/workspace:Z \
  -v /var/run/docker.sock:/var/run/docker.sock \
  iot-dev bash /workspace/test_deploy.sh
```

El flag `-v /var/run/docker.sock:/var/run/docker.sock` permite verificar los contenedores locales desde dentro del contenedor dev.

**21 checks en 9 secciones:**

| Sección | Checks |
|---------|--------|
| AWS | Credenciales válidas |
| S3 | Bucket existe + tiene archivos |
| DynamoDB | 2 tablas en estado ACTIVE |
| Lambda | 3 funciones en estado Active |
| EC2 | Instancia PostgreSQL running |
| ECS | Al menos 1 tarea Fargate activa |
| API REST | `/health`, `/sensors`, `/current`, `/recent`, `/history` respondiendo con datos reales |
| Alertas | Cola SQS existe + entradas HIGH_TEMPERATURE en CloudWatch (última hora) |
| Contenedores | 4 contenedores locales corriendo |

Resultado esperado: `RESULTADO: 21/21 OK — Todo funcionando ✓`

---

## 10. Convenciones y Decisiones de Diseño

### Nomenclatura de recursos AWS

- Patrón: `{project_name}-{recurso}-{environment}` → e.g. `iot-saas-alerts-lab`
- Tablas DynamoDB: `SensorData-lab`, `SensorsRegistry-lab` (PascalCase heredado del lab base)
- Funciones Lambda: `iot-{función}` sin sufijo de entorno (para simplificar referencias)

### Terraform

- Un módulo por servicio AWS (alta cohesión, bajo acoplamiento)
- Los outputs de un módulo son los inputs del siguiente (inyección de dependencias explícita en `main.tf`)
- Todas las variables tienen `default` → no se necesita `terraform.tfvars`
- Se usan `data sources` para todo lo que el Learner Lab provee (roles, VPC, AMIs)
- Los archivos generados localmente (`mosquitto.conf`, certificados) van en `.gitignore`

### Python

- Timestamp: ISO 8601 UTC con `datetime.now(timezone.utc).isoformat()`
- Driver PostgreSQL: `pg8000` (puro Python) en lugar de `psycopg2` (requiere compilación)
- Credenciales siempre por variables de entorno, nunca en el código
- Los tipos `Decimal` de DynamoDB se convierten a `float` antes de serializar a JSON
- Alertas: `logger.warning()` en vez de `print()` para filtrar por nivel en CloudWatch

### Docker y entorno de desarrollo

- En Fedora (SELinux): montar volúmenes con `:Z` para que SELinux lo permita
- La imagen de la API se publica en Docker Hub (no ECR) para simplificar autenticación en Learner Lab
- Dependencias de Lambda se instalan en el mismo directorio que `handler.py` → el ZIP incluye todo

### Seguridad de red

```
Internet → ALB (sg: :80 abierto)
ALB     → ECS Tasks (sg: :8000 solo desde ALB)
ECS     → PostgreSQL EC2 (sg: :5432 solo desde ECS y Lambda)
Lambda  → PostgreSQL EC2 (sg: :5432 solo desde Lambda y ECS)
Lambda  → S3 vía VPC Gateway Endpoint (gratuito, sin salir a internet)
```

---

## 11. Problemas Conocidos y Soluciones

### S3 Event Notification URL-encodea las keys

**Síntoma:** Lambda `iot-s3-to-postgres` fallaba con `NoSuchKey` aunque el archivo existía en S3.

**Causa:** Los eventos de S3 URL-encodean el campo `object.key`. El `=` en `year=2026/month=06/day=04` se transforma en `year%3D2026/month%3D06/day%3D04`. Al pasar ese key a `s3.get_object()`, AWS no encuentra el objeto (que sí existe con `=` literal).

**Solución aplicada:**
```python
from urllib.parse import unquote_plus
key = unquote_plus(record["s3"]["object"]["key"])  # siempre decodificar
```

Este es un gotcha conocido de AWS. Es buena práctica aplicar `unquote_plus` siempre que se reciba un key de un evento S3.

### t3.micro no disponible en us-east-1e

**Síntoma:** `terraform apply` fallaba con `Your requested instance type (t3.micro) is not supported in your requested Availability Zone (us-east-1e)`.

**Causa:** `tolist(data.aws_subnets.default.ids)[0]` seleccionaba aleatoriamente una subnet en `us-east-1e`, AZ que no soporta `t3.micro` en este Learner Lab.

**Solución aplicada:** Data source con filtro explícito de AZ:
```hcl
data "aws_subnet" "postgres_az" {
  filter { name = "vpc-id";           values = [data.aws_vpc.default.id] }
  filter { name = "availabilityZone"; values = ["us-east-1a"] }
}
```

### Credenciales temporales del Learner Lab

Las credenciales expiran (~4 horas). Al iniciar nueva sesión:
1. Copiar nuevas credenciales del portal del Learner Lab
2. Exportarlas antes de entrar al contenedor de desarrollo
3. Terraform las lee de las variables de entorno automáticamente

El `terraform.tfstate` persiste entre sesiones, por lo que `terraform apply` solo actualiza los recursos que cambiaron.

### Dependencia circular Terraform: messaging ↔ lambda

**Causa:** El Event Source Mapping (SQS→Lambda) necesita tanto el ARN de la cola (messaging) como el ARN de la Lambda (lambda). Si messaging referenciara la Lambda, habría un ciclo.

**Solución:** El `aws_lambda_event_source_mapping` vive en el módulo `lambda`. El módulo `messaging` solo crea la cola SQS sin ninguna referencia a Lambda.
