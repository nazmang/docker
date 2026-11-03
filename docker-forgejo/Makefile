STACK_NAME := forgejo
COMPOSE_FILE := docker-compose.yml
DOCKER_CONTEXT ?= default

.PHONY: all deploy status logs
all: deploy

deploy:
	@export $(shell grep -v '^#' .env | xargs) && \
	envsubst < $(COMPOSE_FILE) | docker --context $(DOCKER_CONTEXT) stack deploy -c - $(STACK_NAME)
	@echo "$(STACK_NAME) stack deployed to context '$(DOCKER_CONTEXT)'."

status:
	@docker --context $(DOCKER_CONTEXT) stack services $(STACK_NAME)

logs:
	@docker --context $(DOCKER_CONTEXT) service logs $(STACK_NAME)_forgejo -f
