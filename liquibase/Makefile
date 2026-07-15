.PHONY: up down logs

up:
	@echo "Starting PostgreSQL and running Liquibase migrations..."
	docker-compose up

down:
	@echo "Stopping and removing containers and volumes..."
	docker-compose down -v

logs:
	@echo "Showing logs..."
	docker-compose logs -f
