# Stage 1: deps — install and compile dependencies
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20241016-slim AS deps

RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Stage 2: build — compile app and create release
FROM deps AS build

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release

# Stage 3: runtime — minimal image for running the release
FROM debian:bookworm-20241016-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

RUN useradd --create-home --shell /bin/bash cortex

WORKDIR /app

RUN mkdir -p /app/data && chown cortex:cortex /app/data

COPY --from=build --chown=cortex:cortex /app/_build/prod/rel/cortex ./

USER cortex

EXPOSE 4000 4001

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=30s \
  CMD curl -f http://localhost:4000/health/ready || exit 1

CMD ["bin/server"]
