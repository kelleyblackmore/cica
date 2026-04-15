# cica

Container Image Cosign Automation — sign OCI images with [cosign](https://github.com/sigstore/cosign) and store signing keys and certificates in [HashiCorp Vault](https://www.vaultproject.io/).

## Contents

| File | Purpose |
|------|---------|
| `Dockerfile` | Image with cosign, Vault CLI, and yq pre-installed |
| `sign-images.sh` | Sign one image or a YAML list; upload keys/certs to Vault |
| `test-signing.sh` | End-to-end integration test (spins up Vault + registry) |
| `images.yaml.example` | Example YAML input format |

## Building the image

```bash
docker build -t cica .
```

## Signing images

### Single image

```bash
docker run --rm \
  -e VAULT_ADDR=https://vault.example.com \
  -e VAULT_TOKEN=<token> \
  cica sign-images.sh registry.example.com/myorg/myapp:v1.0.0
```

### YAML list of images

```yaml
# images.yaml
images:
  - registry.example.com/myorg/app1:v1.0.0
  - registry.example.com/myorg/app2:latest
```

```bash
docker run --rm \
  -e VAULT_ADDR=https://vault.example.com \
  -e VAULT_TOKEN=<token> \
  -v $(pwd)/images.yaml:/workspace/images.yaml:ro \
  cica sign-images.sh --file /workspace/images.yaml
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_ADDR` | `http://127.0.0.1:8200` | Vault server URL |
| `VAULT_TOKEN` | *(required)* | Vault authentication token |
| `COSIGN_PASSWORD` | `""` | Password to encrypt the signing key (empty = unencrypted) |
| `COSIGN_ALLOW_INSECURE` | `false` | Set `true` to allow plain-HTTP registries (testing only) |
| `CERT_DAYS` | `365` | Self-signed certificate validity in days |

## Vault path structure

Keys and certificates are stored at:

```
kv/container-images/<image-name>/signing
```

Each secret contains:

| Field | Description |
|-------|-------------|
| `private_key` | Cosign-encrypted SIGSTORE private key |
| `public_key` | EC P-256 public key (PEM) |
| `certificate` | Self-signed X.509 certificate (PEM) |
| `image_reference` | Full image reference that was signed |
| `signed_at` | RFC 3339 timestamp of when the image was signed |

## Running the tests

Requires Docker. Stands up a Vault dev server and a local OCI registry, runs both single-image and YAML-list signing, verifies Vault contents, and validates the cosign signature.

```bash
bash test-signing.sh
```
