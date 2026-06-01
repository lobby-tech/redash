#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Verifica se está rodando como root ---
if [[ $EUID -ne 0 ]]; then
  error "Execute como root: sudo bash setup.sh"
fi

# --- Instala Docker se necessário ---
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker já instalado: $(docker --version)"
    return
  fi

  info "Instalando Docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable --now docker
  info "Docker instalado com sucesso."
}

# --- Gera o arquivo .env a partir do .env.example ---
setup_env() {
  local env_file="$SCRIPT_DIR/.env"
  local env_example="$SCRIPT_DIR/.env.example"

  if [[ -f "$env_file" ]]; then
    warn ".env já existe. Pulando geração de secrets."
    warn "Para recriar, delete o arquivo .env e rode o script novamente."
    return
  fi

  if [[ ! -f "$env_example" ]]; then
    error "Arquivo .env.example não encontrado em $SCRIPT_DIR"
  fi

  info "Gerando .env com secrets aleatórios..."
  cp "$env_example" "$env_file"

  local cookie_secret pg_password secret_key
  cookie_secret=$(openssl rand -hex 32)
  secret_key=$(openssl rand -hex 32)
  pg_password=$(openssl rand -hex 16)

  sed -i "s|REDASH_COOKIE_SECRET=.*|REDASH_COOKIE_SECRET=${cookie_secret}|" "$env_file"
  sed -i "s|REDASH_SECRET_KEY=.*|REDASH_SECRET_KEY=${secret_key}|" "$env_file"
  sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" "$env_file"
  sed -i "s|REDASH_DATABASE_URL=postgresql://postgres:.*@postgres/postgres|REDASH_DATABASE_URL=postgresql://postgres:${pg_password}@postgres/postgres|" "$env_file"

  info ".env gerado em $env_file"
  warn "Edite o .env para configurar REDASH_GOOGLE_CLIENT_ID e REDASH_GOOGLE_CLIENT_SECRET antes de continuar."
}

# --- Pergunta se o usuário já configurou o Google OAuth ---
prompt_google_oauth() {
  local env_file="$SCRIPT_DIR/.env"
  local client_id
  client_id=$(grep -E '^REDASH_GOOGLE_CLIENT_ID=' "$env_file" | cut -d= -f2)

  if [[ -z "$client_id" ]]; then
    echo ""
    warn "REDASH_GOOGLE_CLIENT_ID está vazio no .env."
    warn "O login via Google NÃO estará habilitado."
    warn "Para habilitar depois: edite o .env e execute 'docker compose up -d'"
    echo ""
    read -r -p "Continuar sem login via Google? [s/N] " resp
    [[ "$resp" =~ ^[sS]$ ]] || error "Setup cancelado. Configure o Google OAuth e tente novamente."
  else
    info "Google OAuth configurado (Client ID: ${client_id:0:10}...)"
  fi
}

# --- Inicializa o banco e sobe os serviços ---
start_services() {
  cd "$SCRIPT_DIR"

  info "Inicializando banco de dados (pode demorar alguns minutos)..."
  docker compose run --rm server create_db

  info "Subindo todos os serviços em background..."
  docker compose up -d

  info "Aguardando o servidor inicializar..."
  local retries=0
  until curl -sf http://localhost/ping | grep -q PONG; do
    sleep 3
    retries=$((retries + 1))
    if [[ $retries -gt 20 ]]; then
      error "Timeout: o servidor não respondeu após 60s. Verifique com: docker compose logs server"
    fi
  done
}

# --- Exibe URL de acesso ---
print_summary() {
  local ip
  ip=$(curl -sf --max-time 3 http://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  Redash instalado com sucesso!${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo -e "  Acesse: ${YELLOW}http://${ip}${NC}"
  echo ""
  echo "  Comandos úteis:"
  echo "    docker compose ps          # status dos serviços"
  echo "    docker compose logs -f     # logs em tempo real"
  echo "    docker compose down        # parar tudo"
  echo ""
}

# --- Main ---
install_docker
setup_env
prompt_google_oauth
start_services
print_summary
