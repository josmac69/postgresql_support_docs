.PHONY: up down agent-logs query-metrics trigger-alert clean

up:
	docker compose up --build -d
	@echo "Waiting 15 seconds for databases to initialize and the agent to start..."
	@sleep 15
	@docker compose ps

down:
	docker compose down -v

agent-logs:
	docker compose logs -f pem-agent

query-metrics:
	@echo "=== Active Registered Agents ==="
	@docker compose exec pem-server-db psql -P pager=off -U postgres -d pem -c "SELECT * FROM pem.agents;"
	@echo "=== Latest Metrics Collected ==="
	@docker compose exec pem-server-db psql -P pager=off -U postgres -d pem -c "SELECT * FROM pem.v_latest_agent_metrics;"
	@echo "=== Active Alerts ==="
	@docker compose exec pem-server-db psql -P pager=off -U postgres -d pem -c "SELECT * FROM pem.alerts;"

trigger-alert:
	@echo "Spiking connection count on db-node to trigger alert..."
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@docker compose exec -d db-node psql -U postgres -d postgres -c "SELECT pg_sleep(10);"
	@echo "Connections spawned. Wait 5s for the agent check and run 'make query-metrics'."

clean: down
	docker system prune -f
