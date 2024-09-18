# Variables
STACK_NAME := jenkins
COMPOSE_FILE := docker-compose.yml

# Default target
.PHONY: all
all: deploy

# Initialize Docker Swarm (if not already done)
.PHONY: init-swarm
init-swarm:
	@docker swarm init || echo "Swarm already initialized"

# Deploy Jenkins stack
.PHONY: deploy
deploy: init-swarm
	@docker stack deploy -c $(COMPOSE_FILE) $(STACK_NAME) 
	@echo "Jenkins stack deployed."

# Check the status of the services
.PHONY: status
status:
	@docker stack services $(STACK_NAME)

# Remove the Jenkins stack
.PHONY: remove
remove:
	@docker stack rm $(STACK_NAME)
	@echo "Jenkins stack removed."

# Clean up any unused Docker resources
.PHONY: cleanup
cleanup:
	@docker system prune -f

# View logs of the Jenkins service
.PHONY: logs
logs:
	@docker service logs $(STACK_NAME)_jenkins -f
