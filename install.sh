#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  Цвета и вспомогательные функции
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}▶ $1${NC}"; }

# ─────────────────────────────────────────────
#  Баннер
# ─────────────────────────────────────────────
clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║        SRE Installer — n8n + pgAdmin         ║"
echo "║     k3s · PostgreSQL · cert-manager · TLS    ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo "Требования: Ubuntu, 2 CPU, 4GB RAM, 20GB диск, root"
echo ""

# ─────────────────────────────────────────────
#  Проверка root
# ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Запустите скрипт от root: sudo bash install.sh"
fi

# ─────────────────────────────────────────────
#  Проверка ОС
# ─────────────────────────────────────────────
step "Проверка системы"

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
if [[ "$OS_ID" != "ubuntu" ]]; then
  error "Поддерживается только Ubuntu. Обнаружено: $OS_ID"
fi
success "Ubuntu обнаружена"

RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [[ $RAM_MB -lt 3800 ]]; then
  error "Недостаточно RAM: ${RAM_MB}MB (минимум 4GB)"
fi
success "RAM: ${RAM_MB}MB"

CPU_COUNT=$(nproc)
if [[ $CPU_COUNT -lt 2 ]]; then
  warn "CPU: ${CPU_COUNT} (рекомендуется минимум 2)"
else
  success "CPU: ${CPU_COUNT}"
fi

DISK_GB=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
if [[ $DISK_GB -lt 15 ]]; then
  error "Недостаточно места на диске: ${DISK_GB}GB (минимум 20GB)"
fi
success "Диск: ${DISK_GB}GB свободно"

# ─────────────────────────────────────────────
#  Сбор данных
# ─────────────────────────────────────────────
step "Настройка"
echo ""

# IP сервера
DETECTED_IP=$(hostname -I | awk '{print $1}')
read -rp "  [1/7] IP этого сервера [${DETECTED_IP}] (Enter чтобы оставить): " SERVER_IP
SERVER_IP="${SERVER_IP:-$DETECTED_IP}"

# Домены
read -rp "  [2/7] Домен для n8n (например n8n.example.com): " N8N_DOMAIN
while [[ -z "$N8N_DOMAIN" ]]; do
  echo "        Домен не может быть пустым"
  read -rp "  [2/7] Домен для n8n: " N8N_DOMAIN
done

read -rp "  [3/7] Домен для pgAdmin (например pgadmin.example.com): " PGADMIN_DOMAIN
while [[ -z "$PGADMIN_DOMAIN" ]]; do
  echo "        Домен не может быть пустым"
  read -rp "  [3/7] Домен для pgAdmin: " PGADMIN_DOMAIN
done

# Email
read -rp "  [4/7] Email (для Let's Encrypt и входа в pgAdmin): " USER_EMAIL
while [[ -z "$USER_EMAIL" || "$USER_EMAIL" != *@* ]]; do
  echo "        Введите корректный email"
  read -rp "  [4/7] Email: " USER_EMAIL
done

# Пароли
read -rsp "  [5/7] Пароль для pgAdmin: " PGADMIN_PASSWORD
echo ""
while [[ ${#PGADMIN_PASSWORD} -lt 6 ]]; do
  echo "        Пароль должен быть не менее 6 символов"
  read -rsp "  [5/7] Пароль для pgAdmin: " PGADMIN_PASSWORD
  echo ""
done

read -rsp "  [6/7] Пароль для PostgreSQL: " POSTGRES_PASSWORD
echo ""
while [[ ${#POSTGRES_PASSWORD} -lt 6 ]]; do
  echo "        Пароль должен быть не менее 6 символов"
  read -rsp "  [6/7] Пароль для PostgreSQL: " POSTGRES_PASSWORD
  echo ""
done

# Timezone
DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
read -rp "  [7/7] Timezone [${DETECTED_TZ}] (Enter чтобы оставить): " USER_TZ
USER_TZ="${USER_TZ:-$DETECTED_TZ}"

# Генерируем encryption key автоматически
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

echo ""
echo -e "${BOLD}Параметры установки:${NC}"
echo "  Сервер IP:       $SERVER_IP"
echo "  n8n домен:       $N8N_DOMAIN"
echo "  pgAdmin домен:   $PGADMIN_DOMAIN"
echo "  Email:           $USER_EMAIL"
echo "  Timezone:        $USER_TZ"
echo ""
read -rp "Продолжить? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "Отменено."
  exit 0
fi

# ─────────────────────────────────────────────
#  Проверка DNS
# ─────────────────────────────────────────────
step "Проверка DNS"

check_dns() {
  local domain=$1
  local expected_ip=$2
  local resolved_ip

  if command -v nslookup &>/dev/null; then
    resolved_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | head -1)
  elif command -v dig &>/dev/null; then
    resolved_ip=$(dig +short "$domain" 2>/dev/null | head -1)
  else
    warn "nslookup и dig не найдены, пропускаем проверку DNS"
    return 0
  fi

  if [[ "$resolved_ip" != "$expected_ip" ]]; then
    echo ""
    echo -e "${RED}DNS не настроен для $domain${NC}"
    echo "  Ожидается: $expected_ip"
    echo "  Получено:  ${resolved_ip:-не резолвится}"
    echo ""
    echo "  Создайте A-запись у вашего DNS провайдера:"
    echo "    $domain → $expected_ip"
    echo ""
    echo "  После создания подождите 5-10 минут и запустите скрипт снова."
    exit 1
  fi
  success "$domain → $resolved_ip"
}

check_dns "$N8N_DOMAIN" "$SERVER_IP"
check_dns "$PGADMIN_DOMAIN" "$SERVER_IP"

# ─────────────────────────────────────────────
#  Установка зависимостей
# ─────────────────────────────────────────────
step "Установка зависимостей"
apt-get update -qq
apt-get install -y -qq curl git dnsutils apt-transport-https ca-certificates openssl
success "Зависимости установлены"

# ─────────────────────────────────────────────
#  Установка k3s
# ─────────────────────────────────────────────
step "Установка k3s (v1.35.5+k3s1)"

K3S_VERSION="v1.35.5+k3s1"

if command -v k3s &>/dev/null; then
  warn "k3s уже установлен, пропускаем"
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
  success "k3s установлен"
fi

# Ждём готовности
info "Ожидаем готовности кластера..."
for i in $(seq 1 20); do
  if k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    success "Кластер готов"
    break
  fi
  if [[ $i -eq 20 ]]; then
    error "Кластер не поднялся за 200 секунд"
  fi
  sleep 10
done

# Настраиваем kubeconfig
mkdir -p /root/.kube
k3s kubectl config view --raw > /root/.kube/config
chmod 600 /root/.kube/config
export KUBECONFIG=/root/.kube/config

# ─────────────────────────────────────────────
#  Настройка Traefik HTTP → HTTPS редирект
# ─────────────────────────────────────────────
step "Настройка Traefik (HTTP → HTTPS редирект)"

kubectl apply -f - <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--entrypoints.web.http.redirections.entrypoint.to=:443"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
EOF

success "Traefik настроен"

# ─────────────────────────────────────────────
#  Установка Helm
# ─────────────────────────────────────────────
step "Установка Helm"

if command -v helm &>/dev/null; then
  warn "Helm уже установлен: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm установлен: $(helm version --short)"
fi

# ─────────────────────────────────────────────
#  Установка cert-manager
# ─────────────────────────────────────────────
step "Установка cert-manager"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout 120s

success "cert-manager установлен"

# ClusterIssuer для Let's Encrypt
info "Создаём ClusterIssuer (Let's Encrypt)..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${USER_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

success "ClusterIssuer создан"

# ─────────────────────────────────────────────
#  Определяем директорию скрипта (для helm чартов)
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/helm"

# ─────────────────────────────────────────────
#  Деплой PostgreSQL
# ─────────────────────────────────────────────
step "Деплой PostgreSQL"

helm upgrade --install postgres "$HELM_DIR/postgres" \
  --set auth.database=n8ndb \
  --set auth.username=n8nuser \
  --set "auth.password=${POSTGRES_PASSWORD}" \
  --wait \
  --timeout 120s

success "PostgreSQL задеплоен"

# ─────────────────────────────────────────────
#  Деплой pgAdmin
# ─────────────────────────────────────────────
step "Деплой pgAdmin"

helm upgrade --install pgadmin "$HELM_DIR/pgadmin" \
  --set "env.PGADMIN_DEFAULT_EMAIL=${USER_EMAIL}" \
  --set "env.PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}" \
  --set "ingress.hosts[0].host=${PGADMIN_DOMAIN}" \
  --set "ingress.hosts[0].paths[0].path=/" \
  --set "ingress.hosts[0].paths[0].pathType=Prefix" \
  --set "ingress.tls[0].hosts[0]=${PGADMIN_DOMAIN}" \
  --set "ingress.tls[0].secretName=pgadmin-tls" \
  --set ingress.enabled=true \
  --wait \
  --timeout 120s

success "pgAdmin задеплоен"

# ─────────────────────────────────────────────
#  Деплой n8n
# ─────────────────────────────────────────────
step "Деплой n8n"

helm upgrade --install n8n "$HELM_DIR/n8n" \
  --set "env.N8N_HOST=${N8N_DOMAIN}" \
  --set "env.WEBHOOK_URL=https://${N8N_DOMAIN}" \
  --set "env.N8N_PROTOCOL=https" \
  --set "env.GENERIC_TIMEZONE=${USER_TZ}" \
  --set "env.N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}" \
  --set "env.DB_TYPE=postgresdb" \
  --set "env.DB_POSTGRESDB_HOST=postgres" \
  --set "env.DB_POSTGRESDB_PORT=5432" \
  --set "env.DB_POSTGRESDB_DATABASE=n8ndb" \
  --set "env.DB_POSTGRESDB_USER=n8nuser" \
  --set "dbPassword=${POSTGRES_PASSWORD}" \
  --set "ingress.hosts[0].host=${N8N_DOMAIN}" \
  --set "ingress.hosts[0].paths[0].path=/" \
  --set "ingress.hosts[0].paths[0].pathType=Prefix" \
  --set "ingress.tls[0].hosts[0]=${N8N_DOMAIN}" \
  --set "ingress.tls[0].secretName=n8n-tls" \
  --wait \
  --timeout 180s

success "n8n задеплоен"

# ─────────────────────────────────────────────
#  Ожидание TLS сертификатов
# ─────────────────────────────────────────────
step "Ожидаем TLS сертификаты от Let's Encrypt"
info "Это может занять 1-3 минуты..."

wait_for_cert() {
  local secret_name=$1
  for i in $(seq 1 30); do
    if kubectl get secret "$secret_name" 2>/dev/null | grep -q "$secret_name"; then
      return 0
    fi
    sleep 10
  done
  return 1
}

if wait_for_cert "n8n-tls"; then
  success "TLS сертификат n8n получен"
else
  warn "Сертификат n8n ещё не готов — проверьте позже: kubectl describe certificate n8n-tls"
fi

if wait_for_cert "pgadmin-tls"; then
  success "TLS сертификат pgAdmin получен"
else
  warn "Сертификат pgAdmin ещё не готов — проверьте позже: kubectl describe certificate pgadmin-tls"
fi

# ─────────────────────────────────────────────
#  Сохраняем encryption key
# ─────────────────────────────────────────────
cat > /root/.n8n-installer.env <<EOF
# SRE Installer — сохранено $(date)
N8N_DOMAIN=${N8N_DOMAIN}
PGADMIN_DOMAIN=${PGADMIN_DOMAIN}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
EOF
chmod 600 /root/.n8n-installer.env

# ─────────────────────────────────────────────
#  Финальный вывод
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║              Установка завершена!            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Ваши сервисы:${NC}"
echo ""
echo -e "  n8n:      ${GREEN}https://${N8N_DOMAIN}${NC}"
echo -e "  pgAdmin:  ${GREEN}https://${PGADMIN_DOMAIN}${NC}"
echo ""
echo -e "${BOLD}Данные для входа в pgAdmin:${NC}"
echo "  Email:    $USER_EMAIL"
echo "  Пароль:   (тот что вы ввели)"
echo ""
echo -e "${BOLD}Как подключить PostgreSQL в pgAdmin:${NC}"
echo "  1. Откройте https://${PGADMIN_DOMAIN}"
echo "  2. Войдите: ${USER_EMAIL} / ваш пароль"
echo "  3. Нажмите «Add New Server»"
echo "  4. Name: любое (например Production)"
echo "  5. Вкладка Connection:"
echo "     Host:     postgres"
echo "     Port:     5432"
echo "     Database: n8ndb"
echo "     Username: n8nuser"
echo "     Password: (пароль PostgreSQL который вы ввели)"
echo "  6. Нажмите Save"
echo ""
echo -e "${BOLD}Полезные команды:${NC}"
echo "  Статус подов:        kubectl get pods"
echo "  Статус сертификатов: kubectl get certificates"
echo "  Логи n8n:            kubectl logs -l app=n8n -f"
echo "  Логи pgAdmin:        kubectl logs -l app=pgadmin -f"
echo ""
echo -e "${YELLOW}Encryption key сохранён в /root/.n8n-installer.env — не удаляйте этот файл!${NC}"
echo ""
