# Variables
SERVICE_NAME := nginx-proxy-manager
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default  # Default context if not specified

# Default target
.PHONY: all
all: up

# Start the services
.PHONY: up
up:
	@docker --context $(DOCKER_CONTEXT) compose -f $(COMPOSE_FILE) up -d
	@echo "Services started using context '$(DOCKER_CONTEXT)'."

# Stop and remove the services
.PHONY: down
down:
	@docker --context $(DOCKER_CONTEXT) compose -f $(COMPOSE_FILE) down -v
	@echo "Services stopped and removed using context '$(DOCKER_CONTEXT)'."

# Check the status of the services
.PHONY: status
status:
	@docker --context $(DOCKER_CONTEXT) compose -f $(COMPOSE_FILE) ps

# View logs of the services
.PHONY: logs
logs:
	@docker --context $(DOCKER_CONTEXT) compose -f $(COMPOSE_FILE) logs -f

# Clean up any unused Docker resources
.PHONY: cleanup
cleanup:
	@docker --context $(DOCKER_CONTEXT) system prune -f