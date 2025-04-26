# Variables
STACK_NAME := fluentd
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default  # Default context if not specified
CONF_VERSION ?= 1
FLUEND_BUFFER_PATH ?= /data/fluentd

# Default target
.PHONY: all
all: deploy-all

# Initialize Docker Swarm (if not already done)
.PHONY: init-swarm
init-swarm:
	@docker --context $(DOCKER_CONTEXT) swarm init || echo "Swarm already initialized or not needed."

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


.PHONY: deploy-service
deploy-service:	
	@export CONF_VERSION=$(CONF_VERSION) FLUEND_BUFFER_PATH=$(FLUEND_BUFFER_PATH) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) stack deploy -c - $(STACK_NAME)
	@rm -f /tmp/rendered-compose.yml
	@echo "${STACK_NAME} $(SERVICE) service deployed to context '$(DOCKER_CONTEXT)'."


.PHONY: deploy-fluentd
deploy-fluentd:
	@$(MAKE) deploy-service SERVICE=fluentd
	@$(MAKE) clean-configs 
 
# Deploy full stack
.PHONY: deploy-all
deploy-all: init-swarm
	@$(MAKE) deploy-fluentd	
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

# View logs of the Fluentd service
.PHONY: logs
logs:
	@docker --context $(DOCKER_CONTEXT) service logs $(STACK_NAME)_fluent-bit -f