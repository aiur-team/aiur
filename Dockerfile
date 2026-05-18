FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

ENV MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise/config \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    PATH=/opt/mise/shims:/usr/local/bin:$PATH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      build-essential \
      ca-certificates \
      curl \
      git \
      libncurses-dev \
      libssl-dev \
      locales \
      m4 \
      unzip \
      wget \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://mise.run | sh && \
    mkdir -p "$MISE_CONFIG_DIR" && \
    chmod -R a+rX /opt/mise

WORKDIR /opt/aiur/elixir

COPY elixir/mise.toml ./mise.toml

RUN mise trust ./mise.toml && \
    mise install && \
    mise exec -- mix local.hex --force && \
    mise exec -- mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./

RUN mise exec -- mix deps.get && \
    MIX_ENV=dev mise exec -- mix deps.compile && \
    MIX_ENV=test mise exec -- mix deps.compile

WORKDIR /opt/aiur

COPY . .

WORKDIR /opt/aiur/elixir

RUN MIX_ENV=dev mise exec -- mix compile && \
    MIX_ENV=test mise exec -- mix compile && \
    chmod -R a+rX /opt/aiur

WORKDIR /workspace
