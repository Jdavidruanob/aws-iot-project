variable "project_name" {
  description = "Nombre del proyecto (usado como prefijo en recursos)"
  type        = string
  default     = "iot-saas"
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string
  default     = "lab"
}

variable "alert_threshold" {
  description = "Temperatura (°C) que dispara la alerta — Regla 3 de IoT Core"
  type        = number
  default     = 35
}

variable "postgres_password" {
  description = "Contraseña para el usuario de PostgreSQL"
  type        = string
  default     = "iotpassword123"
  sensitive   = true
}

variable "api_image" {
  description = "Imagen Docker de la API (Docker Hub). Ej: jdavidruanob/iot-api:latest"
  type        = string
  default     = "jdavidruanob/iot-api:latest"
}
