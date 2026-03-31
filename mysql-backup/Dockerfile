FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq \
        cron \
        python3 \
        python3-pip \
        curl \
        default-mysql-client \
        gzip \
        findutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
