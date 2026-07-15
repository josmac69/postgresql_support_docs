.PHONY: up down status topology stop-leader start-all logs clean

up:
	docker compose up --build -d
	@echo "Waiting 10s for the cluster to bootstrap..."
	@sleep 10
	@$(MAKE) status

down:
	docker compose down -v

status:
	@docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list

topology:
	@docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml topology

stop-leader:
	@echo "Checking which node is the current leader..."
	@if curl -s -o /dev/null -w "%{http_code}" http://localhost:8009/primary | grep -q "200"; then \
		echo "patroni1 is leader. Stopping patroni1..."; \
		docker compose stop patroni1; \
	else \
		echo "patroni2 is leader. Stopping patroni2..."; \
		docker compose stop patroni2; \
	fi

start-all:
	docker compose start
	@echo "Waiting 5s for the cluster to stabilize..."
	@sleep 5
	@$(MAKE) status

logs:
	docker compose logs -f

clean: down
	docker system prune -f
