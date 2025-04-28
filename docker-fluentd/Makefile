# Variables
STACK_NAME := fluentd
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default  # Default context if not specified
CONF_VERSION ?= 1
FLUEND_BUFFER_PATH ?= /data/fluentd
FLUEND_CONFIG_PATH ?= /data/fluentd-config

# Default target
.PHONY: all
all: deploy-all

# Initialize Docker Swarm (if not already done)
# .PHONY: init-swarm
# init-swarm:
# 	@docker --context $(DOCKER_CONTEXT) swarm init || echo "Swarm already initialized or not needed."

# .PHONY: clean-configs
# clean-configs:
# 	@echo "Cleaning up old configs (keeping version suffix fluentd-config_v$(CONF_VERSION))..."
# 	@for config in $$(docker config ls --format '{{.Name}}' | grep 'fluentd-config_v'); do \
# 		if echo "$$config" | grep -q "fluentd-config_v$(CONF_VERSION)$$"; then \
# 			echo "Keeping current config: $$config"; \
# 		else \
# 			echo "Removing outdated config: $$config"; \
# 			docker config rm "$$config" || true; \
# 		fi; \
# 	done


.PHONY: deploy-service
deploy-service:	
	@export FLUEND_BUFFER_PATH=$(FLUEND_BUFFER_PATH) FLUEND_CONFIG_PATH=$(FLUEND_CONFIG_PATH) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) compose up -d 
	@rm -f /tmp/rendered-compose.yml
	@echo "${STACK_NAME} $(SERVICE) service deployed to context '$(DOCKER_CONTEXT)'."


.PHONY: deploy-fluentd
deploy-fluentd:
	@$(MAKE) deploy-service SERVICE=fluentd
 
# Deploy all 
.PHONY: deploy-all
deploy-all: 
	@$(MAKE) deploy-fluentd	
	@echo "${STACK_NAME} deployed to context '$(DOCKER_CONTEXT)'."

# Check the status of the services
.PHONY: status
status:
	@docker --context $(DOCKER_CONTEXT) compose ps 

# Remove the 
.PHONY: remove
remove:
	@echo "Removing '$(STACK_NAME)'..."
	@docker --context $(DOCKER_CONTEXT) compose down $(STACK_NAME)
	@echo "Removing volumes for '$(STACK_NAME)'..."
	@VOLUMES=$$(docker --context $(DOCKER_CONTEXT) volume ls -q --filter name=$(STACK_NAME)); \
	if [ -n "$$VOLUMES" ]; then \
		docker --context $(DOCKER_CONTEXT) volume rm $$VOLUMES; \
	else \
		echo "No volumes to remove."; \
	fi
	@echo "$(STACK_NAME) removed from context '$(DOCKER_CONTEXT)'."
	
# Clean up any unused Docker resources
.PHONY: cleanup
cleanup:
	@docker --context $(DOCKER_CONTEXT) system prune -f

# View logs of the Fluentd service
.PHONY: logs
logs:
	@docker --context $(DOCKER_CONTEXT) compose logs -f