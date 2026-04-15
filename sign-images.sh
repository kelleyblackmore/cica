#!/usr/bin/env bash
# sign-images.sh
# Signs container images with cosign and stores the signing key, public key,
# and certificate in HashiCorp Vault.
#
# Usage:
#   sign-images.sh <image>
#   sign-images.sh --file <images.yaml>
#
# Required environment variables:
#   VAULT_TOKEN   — Vault authentication token
#
# Optional environment variables:
#   VAULT_ADDR              — Vault server address (default: http://127.0.0.1:8200)
#   COSIGN_PASSWORD         — Password to encrypt cosign key (default: empty)
#   COSIGN_ALLOW_INSECURE   — Set to "true" to allow insecure (HTTP) registries
#   CERT_DAYS               — Certificate validity in days (default: 365)
#
# YAML file format (--file):
#   images:
#     - registry/org/app1:tag
#     - registry/org/app2:tag
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
COSIGN_ALLOW_INSECURE="${COSIGN_ALLOW_INSECURE:-false}"
CERT_DAYS="${CERT_DAYS:-365}"

_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR"' EXIT

# ── helpers ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <image>
       $(basename "$0") --file <images.yaml>

Options:
  -f, --file <path>   YAML file containing a list of images to sign
  -h, --help          Show this help

YAML file format:
  images:
    - ghcr.io/myorg/app1:v1.0
    - ghcr.io/myorg/app2:latest

Environment variables:
  VAULT_ADDR              Vault server address (default: http://127.0.0.1:8200)
  VAULT_TOKEN             Vault auth token (required)
  COSIGN_PASSWORD         Signing key password (default: empty)
  COSIGN_ALLOW_INSECURE   Allow insecure registries: true|false (default: false)
  CERT_DAYS               Self-signed cert validity in days (default: 365)
EOF
    exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in cosign vault openssl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}

check_vault() {
    [[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is not set"
    VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
        vault status >/dev/null 2>&1 \
        || die "Cannot reach Vault at $VAULT_ADDR — check VAULT_ADDR and VAULT_TOKEN"
}

# Extract a short image name for use as the Vault path component.
# Examples:
#   ghcr.io/myorg/myapp:v1.0        -> myapp
#   localhost:5000/test/alpine:latest -> alpine
#   nginx:latest                    -> nginx
image_to_name() {
    echo "$1" | sed 's|.*/||; s|:.*||'
}

# ── core signing logic ────────────────────────────────────────────────────────

sign_image() {
    local image="$1"
    local name
    name="$(image_to_name "$image")"
    local vault_path="kv/container-images/${name}/signing"
    local work_dir="$_TMPDIR/${name}-$$"
    mkdir -p "$work_dir"

    echo "  [${name}] Generating EC P-256 signing key and self-signed certificate..."

    # 1. Generate raw EC P-256 private key (SEC1 PEM)
    openssl ecparam \
        -name prime256v1 \
        -genkey \
        -noout \
        -out "$work_dir/ec.key" \
        2>/dev/null

    # 2. Extract public key
    openssl ec \
        -in "$work_dir/ec.key" \
        -pubout \
        -out "$work_dir/signing.pub" \
        2>/dev/null

    # 3. Self-signed X.509 certificate (public key matches the signing key)
    openssl req -new -x509 \
        -key  "$work_dir/ec.key" \
        -out  "$work_dir/signing.crt" \
        -days "$CERT_DAYS" \
        -subj "/CN=${name}/O=container-image-signing/OU=cosign" \
        2>/dev/null

    # 4. Wrap the raw EC key in cosign's native SIGSTORE format so cosign sign
    #    can use it directly. The resulting signing.pub will match signing.crt.
    COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign import-key-pair \
        --key "$work_dir/ec.key" \
        --output-key-prefix "$work_dir/signing" \
        2>/dev/null

    # Create a self-signed X.509 certificate for the signing key
    openssl req -new -x509 \
        -key  "$work_dir/signing.key" \
        -out  "$work_dir/signing.crt" \
        -days "$CERT_DAYS" \
        -subj "/CN=${name}/O=container-image-signing/OU=cosign" \
        2>/dev/null

    echo "  [${name}] Signing image: ${image}"

    local cosign_args=(
        sign
        --key  "$work_dir/signing.key"
        --cert "$work_dir/signing.crt"
        --tlog-upload=false
        --yes
    )
    [[ "$COSIGN_ALLOW_INSECURE" == "true" ]] && cosign_args+=(--allow-insecure-registry)

    COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign "${cosign_args[@]}" "$image" \
        || { echo "  [${name}] WARNING: cosign sign failed — image may not exist in registry" >&2; }

    echo "  [${name}] Storing keys & certificate in Vault at ${vault_path}..."

    VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
        vault kv put "$vault_path" \
            private_key="$(cat "$work_dir/signing.key")" \
            public_key="$(cat  "$work_dir/signing.pub")" \
            certificate="$(cat "$work_dir/signing.crt")" \
            image_reference="$image" \
            signed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "  [${name}] Done. Vault path: ${vault_path}"
}

# ── YAML list parsing ─────────────────────────────────────────────────────────

parse_yaml_images() {
    local yaml_file="$1"
    command -v yq &>/dev/null || die "'yq' is required to parse YAML files"
    [[ -f "$yaml_file" ]] || die "File not found: $yaml_file"

    local count
    count="$(yq '.images | length' "$yaml_file")"
    [[ "$count" -gt 0 ]] \
        || die "No entries found under the 'images:' key in ${yaml_file}"

    yq '.images[]' "$yaml_file"
}

# ── entrypoint ────────────────────────────────────────────────────────────────

main() {
    check_deps

    local file_mode=false
    local yaml_file=""
    local images=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|-f)
                [[ $# -ge 2 ]] || die "--file requires a path argument"
                file_mode=true
                yaml_file="$2"
                shift 2
                ;;
            --help|-h) usage ;;
            -*) die "Unknown option: $1" ;;
            *)  images+=("$1"); shift ;;
        esac
    done

    if "$file_mode"; then
        while IFS= read -r img; do
            [[ -n "$img" ]] && images+=("$img")
        done < <(parse_yaml_images "$yaml_file")
    fi

    [[ ${#images[@]} -gt 0 ]] || usage

    check_vault

    echo "==> Signing ${#images[@]} image(s)"
    for img in "${images[@]}"; do
        sign_image "$img"
    done

    echo "==> Complete — all keys and certificates stored in Vault"
}

main "$@"
