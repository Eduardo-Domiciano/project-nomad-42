#!/usr/bin/env bash
# Sobe o Project NOMAD a partir do código deste repositório (build local + compose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="$ROOT/install/compose.from-source.yaml"
ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker não encontrado. Instale o Docker e tente de novo." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Precisa do plugin 'docker compose' (v2)." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_EXAMPLE" ]]; then
    echo "Arquivo .env.example não encontrado em $ROOT" >&2
    exit 1
  fi
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "Criado .env a partir de .env.example"
fi

# Carrega .env para ler/gerar valores
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 48 /dev/urandom | xxd -p | tr -d '\n' | head -c 48
  fi
}

write_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    # Escapa / e & para sed
    local escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

changed=false
if [[ -z "${APP_KEY:-}" || "$APP_KEY" == "replaceme" ]]; then
  APP_KEY="$(rand_secret)"
  write_env_var APP_KEY "$APP_KEY"
  changed=true
fi
if [[ -z "${DB_PASSWORD:-}" || "$DB_PASSWORD" == "replaceme" ]]; then
  DB_PASSWORD="$(rand_secret)"
  write_env_var DB_PASSWORD "$DB_PASSWORD"
  changed=true
fi
if [[ -z "${MYSQL_ROOT_PASSWORD:-}" || "$MYSQL_ROOT_PASSWORD" == "replaceme" ]]; then
  MYSQL_ROOT_PASSWORD="$(rand_secret)"
  write_env_var MYSQL_ROOT_PASSWORD "$MYSQL_ROOT_PASSWORD"
  changed=true
fi

# Recarrega após possíveis writes
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

NOMAD_DATA_DIR="${NOMAD_DATA_DIR:-/opt/project-nomad}"
URL="${URL:-http://localhost:8080}"

# Metadados de build (CI/CD pode exportar VERSION / VCS_REF / BUILD_DATE)
if [[ -z "${VERSION:-}" || "$VERSION" == "dev" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    VERSION="$(git -C "$ROOT" rev-parse --short HEAD)"
  else
    VERSION=dev
  fi
fi
VCS_REF="${VCS_REF:-$VERSION}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export VERSION VCS_REF BUILD_DATE

if [[ "$changed" == true ]]; then
  echo "Segredos gerados e gravados em .env"
fi

echo "Criando diretórios de dados em ${NOMAD_DATA_DIR}..."
if ! mkdir -p \
  "${NOMAD_DATA_DIR}/storage/logs" \
  "${NOMAD_DATA_DIR}/storage/kb_uploads" \
  "${NOMAD_DATA_DIR}/mysql" \
  "${NOMAD_DATA_DIR}/redis" 2>/dev/null
then
  echo "Sem permissão em ${NOMAD_DATA_DIR}."
  echo "Rode com sudo, ou defina NOMAD_DATA_DIR no .env para um caminho gravável (ex.: $ROOT/data)."
  exit 1
fi

# Copia o compose resolvido para o data dir (o sidecar updater espera achar o stack aí)
DEPLOYED_COMPOSE="${NOMAD_DATA_DIR}/compose.yml"
cp "$COMPOSE_FILE" "$DEPLOYED_COMPOSE"
# Também espelha o .env junto do compose implantado
cp "$ENV_FILE" "${NOMAD_DATA_DIR}/.env"

echo "Build e start dos containers..."
docker compose \
  --project-name project-nomad \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  up -d --build

echo
echo "NOMAD subindo."
echo "  Interface:  ${URL}"
echo "  Dados:      ${NOMAD_DATA_DIR}"
echo "  Logs:       docker compose -p project-nomad -f ${COMPOSE_FILE} --env-file ${ENV_FILE} logs -f admin"
echo
echo "Aguarde o healthcheck do admin (pode levar 1–2 min no primeiro boot)."
