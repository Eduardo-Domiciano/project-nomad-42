#!/usr/bin/env bash
# Primeiro setup do NOMAD numa VPS a partir deste repositório.
# Rode NA VPS, dentro da pasta clonada do repo:
#   git clone <seu-repo> /opt/nomad-src && cd /opt/nomad-src
#   bash install/setup_vps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Verificando Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "Instale o Docker antes. Em Ubuntu/Debian:"
  echo "  curl -fsSL https://get.docker.com | sudo sh"
  echo "  sudo usermod -aG docker \$USER   # depois faça logout/login"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Instale o plugin docker compose v2."
  exit 1
fi

if [[ ! -f "$ROOT/.env.example" ]]; then
  echo "Arquivo .env.example não encontrado em $ROOT" >&2
  exit 1
fi

if [[ ! -f "$ROOT/.env" ]]; then
  cp "$ROOT/.env.example" "$ROOT/.env"

  # Descobre IP público/local para preencher URL
  DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  DETECTED_IP="${DETECTED_IP:-127.0.0.1}"

  if grep -q '^URL=' "$ROOT/.env"; then
    sed -i "s|^URL=.*|URL=http://${DETECTED_IP}:8080|" "$ROOT/.env"
  else
    echo "URL=http://${DETECTED_IP}:8080" >> "$ROOT/.env"
  fi

  echo "Criado .env com URL=http://${DETECTED_IP}:8080"
  echo "Edite .env se o IP/domínio estiver errado: nano $ROOT/.env"
else
  echo ".env já existe — mantendo valores atuais."
fi

# Garante pasta de dados (padrão /opt/project-nomad)
NOMAD_DATA_DIR="$(grep -E '^NOMAD_DATA_DIR=' "$ROOT/.env" | cut -d= -f2- || true)"
NOMAD_DATA_DIR="${NOMAD_DATA_DIR:-/opt/project-nomad}"
if [[ ! -d "$NOMAD_DATA_DIR" ]]; then
  echo "==> Criando $NOMAD_DATA_DIR ..."
  if mkdir -p "$NOMAD_DATA_DIR" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$NOMAD_DATA_DIR"
    sudo chown "$(id -u):$(id -g)" "$NOMAD_DATA_DIR"
  else
    echo "Não foi possível criar $NOMAD_DATA_DIR. Defina NOMAD_DATA_DIR no .env para um caminho gravável."
    exit 1
  fi
fi

echo "==> Subindo containers (build na VPS)..."
bash "$ROOT/install/up_from_source.sh"

echo
echo "Setup inicial concluído."
echo "Próximos deploys (na VPS):"
echo "  cd $ROOT && git pull && bash install/up_from_source.sh"
echo "Ou configure o workflow .github/workflows/deploy-vps.yml no GitHub."
echo
echo "Libere no firewall as portas HOST_PORT (padrão 8080) e 9999 (Dozzle), se necessário."
