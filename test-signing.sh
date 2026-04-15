#!/usr/bin/env bash
# test-signing.sh
# Stands up a local Docker registry and a HashiCorp Vault dev server, then
# exercises sign-images.sh for both a single image and a YAML list.
#
# Requires: docker, curl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── configuration ─────────────────────────────────────────────────────────────
SIGNING_IMAGE="cica-signing:test"
VAULT_CONTAINER="cica-vault-test"
REGISTRY_CONTAINER="cica-registry-test"
DOCKER_NETWORK="cica-test"

VAULT_DEV_TOKEN="test-root-token"
VAULT_HOST_PORT="18200"      # host-side port for Vault API (avoids conflicts)
REGISTRY_HOST_PORT="15001"   # host-side port for the local registry

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "==> Cleaning up test environment..."
    docker rm -f "$VAULT_CONTAINER" "$REGISTRY_CONTAINER" 2>/dev/null || true
    docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
    docker rmi "$SIGNING_IMAGE" 2>/dev/null || true
    rm -f /tmp/cica-test-images.yaml /tmp/cica-verify.pub
}
trap cleanup EXIT INT TERM

# ── preflight ─────────────────────────────────────────────────────────────────
for cmd in docker curl; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found" >&2; exit 1; }
done

# Helper: run sign-images.sh inside the signing container on the Docker network.
# The signing container reaches Vault and the registry via container-name DNS.
run_sign() {
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e VAULT_ADDR="http://${VAULT_CONTAINER}:8200" \
        -e VAULT_TOKEN="$VAULT_DEV_TOKEN" \
        -e COSIGN_ALLOW_INSECURE=true \
        "$SIGNING_IMAGE" \
        sign-images.sh "$@"
}

# Helper: run an arbitrary command inside the signing container on the network.
run_in_signing() {
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e VAULT_ADDR="http://${VAULT_CONTAINER}:8200" \
        -e VAULT_TOKEN="$VAULT_DEV_TOKEN" \
        "$SIGNING_IMAGE" \
        "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================="
echo "  Container Image Signing — Integration Tests"
echo "================================================="

# ── Step 1: build the signing image ──────────────────────────────────────────
echo ""
echo "==> [1/6] Building signing image..."
docker build -q -t "$SIGNING_IMAGE" "$SCRIPT_DIR"
echo "    Built: $SIGNING_IMAGE"

# ── Step 2: start infrastructure ─────────────────────────────────────────────
echo ""
echo "==> [2/6] Starting Vault and registry containers..."

docker network create "$DOCKER_NETWORK" 2>/dev/null \
    || echo "    (network already exists)"

# Vault dev server
# SKIP_SETCAP=true avoids the entrypoint's `setcap cap_ipc_lock` call, which
# fails inside a devcontainer where CAP_SETFCAP is not available.
docker rm -f "$VAULT_CONTAINER" 2>/dev/null || true
docker run -d \
    --name "$VAULT_CONTAINER" \
    --network "$DOCKER_NETWORK" \
    -e SKIP_SETCAP=true \
    -e VAULT_DISABLE_MLOCK=true \
    -p "${VAULT_HOST_PORT}:8200" \
    hashicorp/vault:latest \
    server \
        -dev \
        -dev-root-token-id="$VAULT_DEV_TOKEN" \
        -dev-listen-address="0.0.0.0:8200" \
    >/dev/null
echo "    Vault  : http://127.0.0.1:${VAULT_HOST_PORT}  (token: ${VAULT_DEV_TOKEN})"

# Local OCI registry
docker rm -f "$REGISTRY_CONTAINER" 2>/dev/null || true
docker run -d \
    --name "$REGISTRY_CONTAINER" \
    --network "$DOCKER_NETWORK" \
    -p "${REGISTRY_HOST_PORT}:5000" \
    registry:2 \
    >/dev/null
echo "    Registry: localhost:${REGISTRY_HOST_PORT}"

# ── Step 3: wait for Vault to be healthy ─────────────────────────────────────
echo ""
echo "==> Waiting for Vault to become ready..."
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${VAULT_HOST_PORT}/v1/sys/health" >/dev/null 2>&1; then
        echo "    Vault is ready (${i}s)"
        break
    fi
    sleep 1
    [[ $i -lt 30 ]] || { echo "ERROR: Vault did not start within 30 s" >&2; exit 1; }
done

# Enable KV v2 at the 'kv/' path via the Vault HTTP API (no CLI required on host)
curl -sf \
    -H "X-Vault-Token: $VAULT_DEV_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"type":"kv-v2"}' \
    "http://127.0.0.1:${VAULT_HOST_PORT}/v1/sys/mounts/kv" \
    >/dev/null
echo "    KV v2 engine enabled at kv/"

# ── Step 4: push test images into the local registry ─────────────────────────
echo ""
echo "==> [3/6] Pushing test images to local registry..."

# Images are tagged with the registry container's name so the signing container
# (on the same Docker network) can reach them as <container-name>:5000/...
for base_image in alpine:latest busybox:latest; do
    short="${base_image%%:*}"
    target="localhost:${REGISTRY_HOST_PORT}/test/${short}:latest"
    container_ref="${REGISTRY_CONTAINER}:5000/test/${short}:latest"

    docker pull -q "$base_image"
    docker tag "$base_image" "$target"
    docker push -q "$target"
    echo "    Pushed  (host)      : $target"
    echo "    Reachable (container): $container_ref"
done

# ── Step 5: run signing tests ─────────────────────────────────────────────────
echo ""
echo "==> [4/6] Test A — sign a single image"
run_sign "${REGISTRY_CONTAINER}:5000/test/alpine:latest"

echo ""
echo "==> [5/6] Test B — sign multiple images from a YAML file"
cat > /tmp/cica-test-images.yaml <<EOF
images:
  - ${REGISTRY_CONTAINER}:5000/test/alpine:latest
  - ${REGISTRY_CONTAINER}:5000/test/busybox:latest
EOF

docker run --rm \
    --network "$DOCKER_NETWORK" \
    -e VAULT_ADDR="http://${VAULT_CONTAINER}:8200" \
    -e VAULT_TOKEN="$VAULT_DEV_TOKEN" \
    -e COSIGN_ALLOW_INSECURE=true \
    -v /tmp/cica-test-images.yaml:/tmp/images.yaml:ro \
    "$SIGNING_IMAGE" \
    sign-images.sh --file /tmp/images.yaml

# ── Step 6: verify Vault contents ────────────────────────────────────────────
echo ""
echo "==> [6/6] Verifying Vault contents..."

for name in alpine busybox; do
    vault_path="kv/container-images/${name}/signing"
    echo ""
    echo "--- ${vault_path} ---"
    run_in_signing vault kv get "$vault_path"
done

# Verify cosign signature using the public key retrieved from Vault
echo ""
echo "==> (Bonus) Verifying cosign signature for alpine..."

# Fetch public key via Vault HTTP API
pub_key="$(curl -sf \
    -H "X-Vault-Token: $VAULT_DEV_TOKEN" \
    "http://127.0.0.1:${VAULT_HOST_PORT}/v1/kv/data/container-images/alpine/signing" \
    | grep -o '"public_key":"[^"]*"' \
    | sed 's/"public_key":"//; s/"$//' \
    | sed 's/\\n/\n/g')"

echo "$pub_key" > /tmp/cica-verify.pub

docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v /tmp/cica-verify.pub:/tmp/verify.pub:ro \
    "$SIGNING_IMAGE" \
    cosign verify \
        --key /tmp/verify.pub \
        --insecure-ignore-tlog \
        --allow-http-registry \
        --allow-insecure-registry \
        "${REGISTRY_CONTAINER}:5000/test/alpine:latest" \
    && echo "    Signature verified OK" \
    || echo "    (Signature verification failed — see output above)"

echo ""
echo "================================================="
echo "  All tests PASSED"
echo "================================================="
