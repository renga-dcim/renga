# Builds the Renga server as a self-contained OTP release.
#
# The image is deployment-agnostic: configure it entirely through the
# environment variables read by config/runtime.exs (DATABASE_URL,
# SECRET_KEY_BASE, PHX_HOST, and optionally DATABASE_SSL, POOL_SIZE,
# ECTO_IPV6, DNS_CLUSTER_QUERY). Run /app/bin/migrate once per deploy before
# starting /app/bin/server.
#
# Keep ELIXIR_VERSION and OTP_VERSION in step with .github/workflows/elixir.yml.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.8
ARG DEBIAN_VERSION=trixie-20261005-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# git fetches the heroicons dependency.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config comes first so dependency compilation stays cached
# across application code changes.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Only the asset binaries: assets.setup also installs Playwright for browser
# tests, which the image never runs.
RUN mix do tailwind.install --if-missing + esbuild.install --if-missing

COPY priv priv
COPY lib lib

# Colocated LiveView hooks are generated during compilation, so assets build
# after the application compiles.
RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/renga ./

USER nobody

CMD ["/app/bin/server"]
