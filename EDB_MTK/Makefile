.PHONY: up down migrate-all migrate-schema migrate-data verify clean

up:
	docker compose up --build -d
	@echo "Waiting for databases to become healthy..."
	@docker compose ps

down:
	docker compose down -v

migrate-all:
	docker compose exec mtk-runner runMTK.sh -sourceType mysql -targetType postgresql sourcedb

migrate-schema:
	docker compose exec mtk-runner runMTK.sh -sourceType mysql -targetType postgresql -schemaOnly sourcedb

migrate-data:
	docker compose exec mtk-runner runMTK.sh -sourceType mysql -targetType postgresql -dataOnly sourcedb

verify:
	@echo "=== Querying Target Postgres DB ==="
	@docker compose exec postgres-target psql -U postgres -d targetdb -c "SELECT * FROM departments;"
	@docker compose exec postgres-target psql -U postgres -d targetdb -c "SELECT * FROM employees;"

clean: down
	docker system prune -f
