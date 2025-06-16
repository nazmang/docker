# Variables
STACK_NAME := gateway
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
	@export $(shell grep -v '^#' .env | xargs) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) stack deploy -c - $(STACK_NAME)
	@rm -f /tmp/rendered-compose.yml
	@echo "${STACK_NAME} $(SERVICE) service deployed to context '$(DOCKER_CONTEXT)'."

# Deploy full stack
.PHONY: deploy-all
deploy-all: init-swarm
	@$(MAKE) deploy-service 	
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

# View logs of the Jenkins service
.PHONY: logs
logs:
	@docker --context $(DOCKER_CONTEXT) service logs $(STACK_NAME)_gateway -f	