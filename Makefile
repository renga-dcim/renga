.PHONY: dev
dev:
	mix phx.server

.PHONY: dev-agent
dev-agent:
	cargo run -p renga-agent -- --config ./dev/agent.toml --state-directory ./dev/agent-state

.PHONY: test
test: ex-test rs-test

.PHONY: ex-test
ex-test:
	mix test

.PHONY: rs-test
rs-test:
	cargo test --workspace

.PHONY: agent-packages
agent-packages:
	./agent/scripts/build-packages.sh

.PHONY: verify-agent-packages
verify-agent-packages:
	./agent/scripts/verify-packages.sh

.PHONY: changelog
changelog:
	git cliff -o CHANGELOG.md

.PHONY: lint
lint: ex-lint rs-lint rs-fmt

.PHONY: check-rfds
check-rfds:
	@./scripts/check-rfd-status.sh
	@./scripts/check-rfd-status-test.sh

.PHONY: ex-lint
ex-lint:
	mix credo

.PHONY: rs-lint
rs-lint:
	cargo clippy --workspace --all-features -- -D warnings

.PHONY: rs-fmt
rs-fmt:
	cargo fmt --all -- --check
	@if rg -n -U '^}\n(?:#\[|(?:(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:fn|struct|enum|trait|impl|type|const|static)\b))' agent/src; then \
		echo 'Rust top-level items must have a blank line between them.' >&2; \
		exit 1; \
	fi

.PHONY: up
up:
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		./scripts/local-postgres.sh start; \
	else \
		docker compose up -d; \
	fi

.PHONY: down
down:
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		./scripts/local-postgres.sh stop; \
	else \
		docker compose stop; \
	fi

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: db
db:
	psql -h "$(CURDIR)/tmp/postgres-socket" -U postgres -d renga_dev

.PHONY: console
console:
	iex -S mix
