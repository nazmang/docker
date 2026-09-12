# Variables
STACK_NAME := monitoring
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default  # Default context if not specified

# Default target
.PHONY: all
all: deploy-all

# Initialize Docker Swarm (if not already done)
.PHONY: init-swarm
init-swarm:
	@docker --context $(DOCKER_CONTEXT) swarm init || echo "Swarm already initialized or not needed."

.PHONY: deploy-service
deploy-service:
ifndef SERVICE
	$(error SERVICE is not defined. Usage: make deploy-service SERVICE=servicename)
endif
# Отступы и пустые строки убираются до разбора, а не после. Здесь стояло
# `grep -v '^#'`, и оно не снимало строки, начинающиеся с ПРОБЕЛОВ и решётки --
# а .env генерируется Jenkins'ом из строки Groovy с отступами, то есть именно
# такие там и есть. Дальше xargs склеивает всё в одну строку, и решётка
# посреди неё становится началом комментария оболочки: всё, что правее,
# пропадает молча. Так исчезали GRAFANA_TAG, PROM_TAG и, главное,
# PROM_CONFIG_VERSION.
#
# Последствие было не «ничего не развернулось», а хуже. Без PROM_CONFIG_VERSION
# все конфиги получали имя *_manual вместо хеша коммита -- имя переставало
# меняться вместе с содержимым. А конфиги Swarm неизменяемы, поэтому второй же
# деплой с другим содержимым падал с "only updates to Labels are allowed", и
# стек не обновлялся вовсе. Найдено 12.09.2026, сборка 158.
	@export $$(sed -E 's/^[[:space:]]+//' .env | grep -vE '^(#|$$)' | xargs) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) stack deploy -c - $(STACK_NAME)
	@rm -f /tmp/rendered-compose.yml
	@echo "${STACK_NAME} $(SERVICE) service deployed to context '$(DOCKER_CONTEXT)'."

# Deploy individual services
.PHONY: deploy-monitoring
deploy-monitoring:
	@$(MAKE) deploy-service SERVICE=monitoring

.PHONY: deploy-cadvisor
deploy-cadvisor:
	@$(MAKE) deploy-service COMPOSE_FILE=docker-compose.cadvisor.yml SERVICE=cadvisor

.PHONY: deploy-nodeexporter
deploy-nodeexporter:
	@$(MAKE) deploy-service COMPOSE_FILE=docker-compose.nodeexporter.yml SERVICE=nodeexporter

.PHONY: deploy-swarmexporter
deploy-swarmexporter:
	@$(MAKE) deploy-service COMPOSE_FILE=docker-compose.swarmexporter.yml SERVICE=swarmexporter

.PHONY: deploy-dockerproxy
deploy-dockerproxy:
	@$(MAKE) deploy-service COMPOSE_FILE=docker-compose.dockerproxy.yml SERVICE=dockerproxy

# Deploy full Monitoring stack
.PHONY: deploy-all
deploy-all: init-swarm
	@$(MAKE) deploy-monitoring 
	@$(MAKE) deploy-cadvisor COMPOSE_FILE=docker-compose.cadvisor.yml
	@$(MAKE) deploy-nodeexporter COMPOSE_FILE=docker-compose.nodeexporter.yml
	@$(MAKE) deploy-dockerproxy COMPOSE_FILE=docker-compose.dockerproxy.yml
	@$(MAKE) deploy-swarmexporter COMPOSE_FILE=docker-compose.swarmexporter.yml
	@echo "${STACK_NAME} stack deployed to context '$(DOCKER_CONTEXT)'."

# Check the status of the services
.PHONY: status
status:
	@docker --context $(DOCKER_CONTEXT) stack services $(STACK_NAME)

# Remove the stack
.PHONY: remove
remove:
	@echo "Removing stack '$(STACK_NAME)'..."
	@docker --context $(DOCKER_CONTEXT) stack rm $(STACK_NAME)	
	@echo "Removing volumes for stack '$(STACK_NAME)'..."
	@bash -c 'docker --context $(DOCKER_CONTEXT) volume rm $(docker --context $(DOCKER_CONTEXT) volume ls -q --filter label=com.docker.stack.namespace=$(STACK_NAME)) || echo "No volumes to remove."'
	@echo "${STACK_NAME} stack removed from context '$(DOCKER_CONTEXT)'."

# Clean up any unused Docker resources
.PHONY: cleanup
cleanup:
	@docker --context $(DOCKER_CONTEXT) system prune -f

