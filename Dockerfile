FROM alpine:3.21

# Build-time versions — override with --build-arg as needed
ARG TARGETARCH=amd64
ARG COSIGN_VERSION=v2.4.1
ARG VAULT_VERSION=1.17.3
ARG YQ_VERSION=v4.44.3

RUN apk add --no-cache \
    bash \
    curl \
    openssl \
    unzip \
    ca-certificates

# ── cosign ────────────────────────────────────────────────────────────────────
RUN curl -fsSL \
        "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
        -o /usr/local/bin/cosign \
    && chmod +x /usr/local/bin/cosign \
    && cosign version

# ── HashiCorp Vault CLI ────────────────────────────────────────────────────────
RUN curl -fsSL \
        "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" \
        -o /tmp/vault.zip \
    && unzip -q /tmp/vault.zip -d /usr/local/bin/ \
    && rm /tmp/vault.zip \
    && vault version

# ── yq (YAML parser) ──────────────────────────────────────────────────────────
RUN curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && yq --version

COPY sign-images.sh /usr/local/bin/sign-images.sh
RUN chmod +x /usr/local/bin/sign-images.sh

WORKDIR /workspace

CMD ["sign-images.sh", "--help"]
