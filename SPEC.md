# Proyecto Final IoT – Especificación Técnica

**Curso:** IoT – Universidad Javeriana Cali  
**Alumno:** Jdavidruanob  
**Base de referencia:** `proyect-context/7_iot_s3_dynamo_athena`  
**Estado actual:** Análisis completado · Esperando respuestas del profesor (ver STATUS.md)

---

## 1. Punto de Partida: Arquitectura Base (Lab 7)

El profesor nos entregó un sistema funcional compuesto por:

**Local (Docker Compose):**
- `sensor-temp-01` — script Python que simula temperatura
- `sensor-humidity-01` — script Python que simula humedad
- `mosquitto` (Edge Gateway) — broker MQTT con bridge a AWS

**Cloud (AWS Learner Lab):**
- **AWS IoT Core** — recibe datos via MQTT sobre TLS (mTLS, puerto 8883)
- **Regla 1 → DynamoDB** — "hot data": sobrescribe el estado más reciente por `device_id` (sin Sort Key, actúa como Device Shadow)
- **Regla 2 → S3** — "cold data": archivos JSON particionados por `year/month/day`

**Infraestructura como Código:** Terraform (módulos: networking, storage, database, iot, compute)  
**Automatización:** Makefile (`make aws-up`, `make local-up`, `make logs`, `make clean`)  
**Certificados:** Terraform genera mTLS (clave privada, cert PEM, Amazon Root CA) e inyecta el endpoint en `mosquitto.conf`

**Formato de mensaje MQTT (tópico `lab/sensors/data`):**
```json
{
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "value": 25.5,
  "timestamp": "2026-05-13T12:00:00+00:00"
}
```

---

## 2. Arquitectura Objetivo (7 Hitos)

```
Local Edge (Docker Compose)
├── sensor-temp-01    → MQTT local → Mosquitto
├── sensor-humidity-01 → MQTT local → Mosquitto
└── [sensor-NEW-01]   → MQTT local → Mosquitto   ← Hito 7 (sustentación)
         │
         ▼ MQTT mTLS 8883
   AWS IoT Core
         │
         ├──[Regla 1]──► DynamoDB (hot: último estado por device_id)
         ├──[Regla 2]──► S3 (cold: JSON particionado /year/month/day/)
         └──[Regla 3: value > UMBRAL]──► Lambda Alerta
                                              │
                                              ▼
                                         SQS Queue
                                              │
                                              ▼ trigger
                                         Lambda CloudWatch
                                              │
                                              ▼
                                         CloudWatch Logs

S3 ──[ObjectCreated trigger]──► Lambda Histórico
                                      │
                                      ▼
                                 MongoDB (histórico completo)

FastAPI (ECS/Fargate)
  ├── GET  /sensors              → DynamoDB
  ├── POST /sensors              → DynamoDB
  ├── GET  /sensor/{id}/current  → DynamoDB
  ├── GET  /sensor/{id}/recent   → DynamoDB (⚠️ ver pregunta P2)
  └── GET  /sensor/{id}/history  → MongoDB  (⚠️ ver pregunta P1)
```

---

## 3. Los 7 Hitos en Detalle

### Hito 1 – MongoDB
Aprovisionar una instancia de MongoDB accesible desde Lambda y la API.  
**Pregunta abierta P3:** ¿EC2, ECS, o DocumentDB? (ver STATUS.md)

### Hito 2 – Lambda S3 Trigger
Función Lambda Python activada por evento `s3:ObjectCreated:*` en el bucket de cold data.

### Hito 3 – Lógica Histórico en Lambda
La Lambda del Hito 2 lee el JSON del objeto S3 e inserta el documento en MongoDB.

Flujo:
```python
event → bucket_name, key → s3.get_object() → json.loads() → mongo.insert_one()
```

### Hito 4 – API REST FastAPI
5 endpoints (ver arquitectura objetivo arriba).  
**Pregunta abierta P1 y P2** afectan el diseño de esta capa.

### Hito 5 – Despliegue en ECS
- Contenedorizar FastAPI con `Dockerfile`
- Publicar imagen en ECR (o Docker Hub, **ver P5**)
- Task Definition en ECS referenciando la imagen
- ECS Service con réplicas deseadas
- ALB para enrutar tráfico externo
- Todo vía Terraform

### Hito 6 – Sistema de Alertas
- **Regla 3 (IoT Core SQL):** `SELECT * FROM 'lab/sensors/data' WHERE sensor_type = 'temperature' AND value > UMBRAL`
- **Lambda Alerta:** recibe el payload de IoT Core, formatea mensaje de emergencia, publica a SQS
- **SQS Queue:** cola estándar
- **Lambda CloudWatch:** suscrita a SQS via Event Source Mapping, escribe log de urgencia en CloudWatch Logs

### Hito 7 – 3er Sensor (Sustentación)
- Añadir nuevo tipo de sensor en `sensor_simulator.py` (tipo libre, ej: presión, CO2, luminosidad)
- Agregar nuevo servicio al `docker-compose.yml`
- Registrar via `POST /sensors`
- Verificar con `GET /sensor/{id}/current` y `GET /sensor/{id}/recent`

---

## 4. Stack Tecnológico

| Capa | Tecnología | Notas |
|------|-----------|-------|
| Protocolo IoT | MQTT | QoS 1, tópico `lab/sensors/data` |
| Edge Broker | Eclipse Mosquitto | Docker, bridge mTLS hacia AWS |
| Cloud IoT | AWS IoT Core | Motor de reglas SQL |
| Hot Data | AWS DynamoDB | PK: `device_id`, sin Sort Key |
| Cold Data | Amazon S3 | Particionado `year/month/day` |
| Histórico | MongoDB | Hito 1 (hosting TBD) |
| Procesamiento | AWS Lambda (Python) | Hito 2/3: S3→Mongo; Hito 6: alertas |
| Cola | Amazon SQS | Hito 6: pipeline de alertas |
| Logs | Amazon CloudWatch | Destino final de alertas |
| API | FastAPI (Python) | 5 endpoints REST |
| Compute API | Amazon ECS (Fargate) | Hito 5 |
| Container Registry | Amazon ECR | TBD – ver P5 |
| IaC | Terraform | Todos los recursos cloud |
| Containers | Docker / Docker Compose | Dev local + sensores |

---

## 5. Entorno de Desarrollo

Basado en la imagen Docker del profesor (`proyect-context/dockerfile`):
- Base: `python:3.12-slim`
- Incluye: Docker CLI, Docker Compose, AWS CLI, Terraform/OpenTofu

**Flujo de trabajo:**
```bash
# Construir imagen de dev
docker build -t iot-dev ./dev-container/

# Levantar contenedor (Fedora: usar :Z por SELinux)
docker run -it -v $(pwd):/app:Z iot-dev bash

# Dentro del contenedor: configurar credenciales temporales AWS
aws configure
# (pegar credenciales del Learner Lab - cambian cada sesión)
```

**IMPORTANTE:** Las credenciales del AWS Learner Lab son temporales y cambian por sesión. Siempre pedir al usuario antes de cualquier operación AWS.

---

## 6. Estructura de Directorios (Planeada)

```
aws-iot-project/
├── SPEC.md                    ← este archivo
├── STATUS.md                  ← estado actual y preguntas
├── ARCHITECTURE.md            ← detalles técnicos (después de aclarar preguntas)
├── Makefile                   ← automatización completa
├── docker-compose.yml         ← sensores locales + edge gateway
│
├── edge_gateway/              ← Mosquitto config + certs (gen. por Terraform)
│   ├── Dockerfile
│   └── certs/                 ← generado por `make aws-up`
│
├── python_device/             ← simuladores de sensores
│   ├── Dockerfile
│   ├── requirements.txt
│   └── sensor_simulator.py    ← incluirá 3er sensor para sustentación
│
├── api/                       ← FastAPI app
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py
│
├── lambda/
│   ├── s3_to_mongo/           ← Hito 2/3: S3 → MongoDB
│   │   └── handler.py
│   ├── alert/                 ← Hito 6: IoT Rule → SQS
│   │   └── handler.py
│   └── cloudwatch_logger/     ← Hito 6: SQS → CloudWatch
│       └── handler.py
│
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── modules/
        ├── storage/            ← S3
        ├── database/           ← DynamoDB + MongoDB
        ├── iot/                ← IoT Core rules + certs
        ├── compute/            ← ECS cluster, task def, service, ALB
        ├── lambda/             ← todas las funciones Lambda
        └── messaging/          ← SQS queue + event source mapping
```
