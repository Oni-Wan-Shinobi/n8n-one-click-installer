# SRE Installer — n8n + pgAdmin + PostgreSQL

Автоматическая установка n8n, pgAdmin и PostgreSQL на чистый сервер с HTTPS через Let's Encrypt.

## Что устанавливается

- **k3s** `v1.35.5+k3s1` — лёгкий Kubernetes
- **cert-manager** — автоматические TLS сертификаты (Let's Encrypt)
- **Traefik** — встроенный в k3s, с редиректом HTTP → HTTPS
- **PostgreSQL 16** — база данных для n8n
- **n8n** `2.21.8` — платформа автоматизации
- **pgAdmin 4** `8` — веб-интерфейс для PostgreSQL

## Требования к серверу

| Параметр | Минимум |
|----------|---------|
| ОС       | Ubuntu (любая версия) |
| CPU      | 2 ядра |
| RAM      | 4 GB |
| Диск     | 20 GB |
| Доступ   | root |

## Требования к DNS

До запуска скрипта создайте две A-записи у вашего DNS провайдера:

```
n8n.example.com      → IP вашего сервера
pgadmin.example.com  → IP вашего сервера
```

Подождите 5-10 минут после создания записей.

## Установка

```bash

# Скачайте репозиторий
git clone https://github.com/your-org/sre-installer.git
cd sre-installer

# Запустите установщик
bash install.sh
```

Скрипт задаст 7 вопросов и сделает всё сам. Установка занимает 5-10 минут.

## Что спрашивает скрипт

1. IP сервера (определяется автоматически)
2. Домен для n8n
3. Домен для pgAdmin
4. Email (для Let's Encrypt и входа в pgAdmin)
5. Пароль для pgAdmin
6. Пароль для PostgreSQL
7. Timezone (берётся с сервера автоматически)

## После установки

### Как подключить PostgreSQL в pgAdmin

1. Откройте `https://pgadmin.example.com`
2. Войдите: ваш email / ваш пароль
3. Нажмите **Add New Server**
4. **Name**: любое (например `Production`)
5. Вкладка **Connection**:
   - Host: `postgres`
   - Port: `5432`
   - Database: `n8ndb`
   - Username: `n8nuser`
   - Password: пароль PostgreSQL который вы вводили
6. Нажмите **Save**

### Полезные команды

```bash
# Статус всех подов
kubectl get pods

# Статус TLS сертификатов
kubectl get certificates

# Логи n8n
kubectl logs -l app=n8n -f

# Логи pgAdmin
kubectl logs -l app=pgadmin -f

# Все Helm релизы
helm list
```

## Важно

Файл `/root/.n8n-installer.env` содержит `N8N_ENCRYPTION_KEY` — **не удаляйте его**.
Без этого ключа n8n не сможет расшифровать сохранённые credentials после перезапуска.
