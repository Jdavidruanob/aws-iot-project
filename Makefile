.PHONY: aws-up aws-down local-up local-down logs clean build-lambdas build-api push-api

# Cambia esto por tu usuario de Docker Hub
DOCKER_HUB_USER ?= jdavidruanob
API_IMAGE = $(DOCKER_HUB_USER)/iot-api:latest

# =============================================================
# Infraestructura AWS (Terraform)
# =============================================================

aws-up: build-lambdas
	@echo "Desplegando infraestructura en AWS..."
	mkdir -p edge_gateway/certs
	cd terraform && terraform init && terraform apply -auto-approve
	@echo ""
	@echo "Infraestructura desplegada. Revisa los outputs para la URL de la API."

aws-down:
	@echo "Destruyendo infraestructura en AWS..."
	cd terraform && terraform destroy -auto-approve
	@echo "Infraestructura destruida."

# =============================================================
# Contenedores Locales (Docker Compose)
# =============================================================

local-up:
	@echo "Levantando sensores y edge gateway locales..."
	docker compose up -d --build
	@echo "Contenedores iniciados. Usa 'make logs' para ver el flujo de datos."

local-down:
	@echo "Deteniendo contenedores locales..."
	docker compose down

logs:
	docker compose logs -f

# =============================================================
# API — Build y publicación en Docker Hub
# =============================================================

build-api:
	@echo "Construyendo imagen Docker de la API..."
	docker build -t $(API_IMAGE) ./api/
	@echo "Imagen construida: $(API_IMAGE)"

push-api: build-api
	@echo "Publicando imagen en Docker Hub (necesitas estar logueado: docker login)..."
	docker push $(API_IMAGE)
	@echo "Imagen publicada: $(API_IMAGE)"
	@echo "Actualiza la variable api_image en terraform/variables.tf con: $(API_IMAGE)"

# =============================================================
# Lambda — Instalar dependencias antes del deploy
# =============================================================

build-lambdas:
	@echo "Instalando dependencias de Lambda s3_to_postgres (pg8000)..."
	pip install -r lambda/s3_to_postgres/requirements.txt \
		-t lambda/s3_to_postgres/ --quiet --upgrade
	@echo "Dependencias instaladas."

# =============================================================
# Limpieza completa
# =============================================================

clean: local-down aws-down
	@echo "Limpiando archivos generados..."
	rm -rf edge_gateway/certs/*
	rm -f edge_gateway/mosquitto.conf
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl
	rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup
	@echo "Entorno limpio."
