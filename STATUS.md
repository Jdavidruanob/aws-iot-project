# Estado del Proyecto

**Fecha última actualización:** 2026-06-04  
**Fase actual:** CÓDIGO COMPLETO — Pendiente de deploy y pruebas en AWS

---

## Hitos de Implementación

| # | Hito | Estado | Notas |
|---|------|--------|-------|
| 1 | PostgreSQL en EC2 | ✅ Implementado | `terraform/modules/postgres/` — EC2 + Docker + schema automático |
| 2 | Lambda S3 Trigger | ✅ Implementado | `lambda/s3_to_postgres/handler.py` — trigger via `aws_s3_bucket_notification` |
| 3 | Lambda S3 → PostgreSQL | ✅ Implementado | Lógica en el mismo handler del Hito 2 |
| 4 | API REST FastAPI (5 endpoints) | ✅ Implementado | `api/main.py` — `/sensors`, `/current`, `/recent`, `/history` |
| 5 | Deploy API en ECS Fargate | ✅ Implementado | `terraform/modules/compute/` — ALB + Task + Service |
| 6 | Sistema de Alertas (SQS) | ✅ Implementado | Regla 3 IoT Core + Lambda alert + SQS + Lambda CloudWatch |
| 7 | 3er Sensor CO2 | ✅ Implementado | `sensor_simulator.py` + `docker-compose.yml` |
| - | Terraform modular completo | ✅ Implementado | 8 módulos independientes |

---

## Preguntas al Profesor

| # | Pregunta | Estado |
|---|----------|--------|
| P1 | MongoDB o PostgreSQL | ✅ PostgreSQL |
| P2 | `/recent` con DynamoDB | ✅ Sort Key (timestamp) — patrón del taller 6 |
| P3 | MongoDB hosting | ✅ No aplica |
| P4 | IAM Learner Lab | ✅ Usar `LabRole` predefinido |
| P5 | ECR o Docker Hub | ✅ Docker Hub |
| P6 | Umbral alerta | ✅ Hardcodeado en SQL de IoT Core (35°C, variable Terraform) |
| P7 | 3er sensor | ✅ CO2 (ppm), libre elección |

---

## Próximos Pasos: Deploy y Pruebas

### Antes del primer deploy
1. Hacer login en Docker Hub: `docker login`
2. Construir y publicar la imagen de la API: `make push-api`

### Deploy completo
```bash
# Dentro del contenedor de desarrollo con credenciales AWS configuradas:
make aws-up      # instala deps de Lambda + terraform apply
make local-up    # levanta sensores locales
make logs        # ver flujo de datos en vivo
```

### Verificaciones post-deploy
- [ ] IoT Core recibe mensajes (MQTT test client en consola AWS)
- [ ] DynamoDB tiene eventos con `device_id` + `timestamp`
- [ ] S3 tiene archivos JSON particionados por fecha
- [ ] PostgreSQL tiene registros en `sensor_events` (Lambda s3_to_postgres)
- [ ] API responde en la URL del ALB: `make outputs` o `terraform output api_url`
- [ ] Temperatura > 35°C dispara alerta: aparece en CloudWatch Logs

---

## Estructura del Proyecto

```
aws-iot-project/
├── Makefile                    ← aws-up, local-up, push-api, clean
├── docker-compose.yml          ← 3 sensores + mosquitto
├── edge_gateway/               ← Mosquitto (certs y conf generados por Terraform)
├── python_device/              ← Simulador: temperature, humidity, co2
├── api/                        ← FastAPI: 5 endpoints REST
├── lambda/
│   ├── s3_to_postgres/         ← S3 ObjectCreated → PostgreSQL
│   ├── alert/                  ← IoT Rule 3 → SQS
│   └── cloudwatch_logger/      ← SQS → CloudWatch Logs
└── terraform/
    ├── modules/storage/        ← S3 bucket (cold data)
    ├── modules/database/       ← DynamoDB events + registry
    ├── modules/networking/     ← Security groups + VPC endpoint S3
    ├── modules/postgres/       ← EC2 + PostgreSQL en Docker
    ├── modules/iot/            ← IoT Core: Thing, certs, 3 reglas
    ├── modules/lambda/         ← 3 funciones Lambda + triggers + ESM
    ├── modules/messaging/      ← SQS queue
    └── modules/compute/        ← ECS Cluster + Task + Service + ALB
```
