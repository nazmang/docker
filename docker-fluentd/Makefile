# Variables
STACK_NAME := fluentd
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default

CONF_VERSION ?= 1
FLUEND_BUFFER_PATH ?= /data/fluentd
FLUEND_CONFIG_PATH ?= /data/fluentd-config

# Image settings
IMAGE_NAME ?= nazman/fluentd
IMAGE_TAG ?= v1.19.2-debian-1.0
REGISTRY ?= docker.io

FULL_IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
BUILD_CONTEXT ?= fluentd
DOCKERFILE ?= $(BUILD_CONTEXT)/Dockerfile

# Default target
.PHONY: all
all: deploy-all

# -----------------------
# Build & Push
# -----------------------

.PHONY: build
build:
	@echo "Building image $(FULL_IMAGE)..."
	@echo "Context: $(BUILD_CONTEXT)"
	@echo "Dockerfile: $(DOCKERFILE)"
	@docker build -f $(DOCKERFILE) -t $(FULL_IMAGE) $(BUILD_CONTEXT)

.PHONY: push
push:
	@echo "Pushing image $(FULL_IMAGE)..."
	@docker push $(FULL_IMAGE)

# -----------------------
# Swarm init
# -----------------------

.PHONY: init-swarm
init-swarm:
	@docker --context $(DOCKER_CONTEXT) swarm init || echo "Swarm already initialized or not needed."

# -----------------------
# Config cleanup
# -----------------------

.PHONY: clean-configs
clean-configs:
	@echo "Cleaning up old configs (keeping version suffix fluentd-config_v$(CONF_VERSION))..."
	@for config in $$(docker config ls --format '{{.Name}}' | grep 'fluentd-config_v'); do \
		if echo "$$config" | grep -q "fluentd-config_v$(CONF_VERSION)$$"; then \
			echo "Keeping current config: $$config"; \
		else \
			echo "Removing outdated config: $$config"; \
			docker config rm "$$config" || true; \
		fi; \
	done

# -----------------------
# Deploy
# -----------------------

.PHONY: deploy-service
deploy-service: build push
ifndef SERVICE
	$(error SERVICE is not defined. Usage: make deploy-service SERVICE=servicename)
endif
	@echo "Deploying service with image $(FULL_IMAGE)..."
	@export $(shell grep -v '^#' .env | xargs) CONF_VERSION=$(CONF_VERSION) \
	FLUEND_BUFFER_PATH=$(FLUEND_BUFFER_PATH) \
	FLUEND_CONFIG_PATH=$(FLUEND_CONFIG_PATH) \
	IMAGE=$(FULL_IMAGE) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) stack deploy -c - $(STACK_NAME)
	@echo "${STACK_NAME} $(SERVICE) service deployed to context '$(DOCKER_CONTEXT)'."

.PHONY: deploy-fluentd
deploy-fluentd:
	@$(MAKE) deploy-service SERVICE=fluentd

# Deploy all
.PHONY: deploy-all
deploy-all:
	@$(MAKE) deploy-fluentd
	@echo "${STACK_NAME} deployed to context '$(DOCKER_CONTEXT)'."

# -----------------------
# Status / Logs
# -----------------------

.PHONY: status
status:
	@docker --context $(DOCKER_CONTEXT) compose ps 

.PHONY: logs
logs:
	@docker --context $(DOCKER_CONTEXT) compose logs -f

# -----------------------
# Remove / Cleanup
# -----------------------

.PHONY: remove
remove:
	@echo "Removing '$(STACK_NAME)'..."
	@docker --context $(DOCKER_CONTEXT) stack rm $(STACK_NAME)
	@echo "Removing volumes for '$(STACK_NAME)'..."
	@VOLUMES=$$(docker --context $(DOCKER_CONTEXT) volume ls -q --filter name=$(STACK_NAME)); \
	if [ -n "$$VOLUMES" ]; then \
		docker --context $(DOCKER_CONTEXT) volume rm $$VOLUMES; \
	else \
		echo "No volumes to remove."; \
	fi
	@echo "$(STACK_NAME) removed from context '$(DOCKER_CONTEXT)'."

.PHONY: cleanup
cleanup:
	@docker --context $(DOCKER_CONTEXT) system prune -f