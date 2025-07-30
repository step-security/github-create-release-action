FROM alpine:3.21@sha256:b6a6be0ff92ab6db8acd94f5d1b7a6c2f0f5d10ce3c24af348d333ac6da80685 AS base

RUN apk add --no-cache jq curl sed

SHELL ["/bin/ash", "-o", "pipefail", "-c"]
RUN SUBMARK_URL="https://github.com/dahlia/submark/releases/download/0.3.1/submark-0.3.1-linux-x86_64" && \
    curl -o /usr/local/bin/submark -sSL "$SUBMARK_URL" && \
    echo "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5  /usr/local/bin/submark" | sha256sum -c - && \
    chmod +x /usr/local/bin/submark

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
