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
	docker compose up -d

.PHONY: down
down:
	docker compose stop

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: db
db:
	psql -h 127.0.0.1 -U postgres -d renga_dev -p 5434 -W

.PHONY: console
console:
	iex -S mix
