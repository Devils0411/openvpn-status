#!/usr/bin/env bash

# Обработка ошибок
set -e

# Переменные
ROOT_DIR="/root/web"  # Корневая папка проекта
DB_DIR="$ROOT_DIR/src/data/databases"
LOGS_DIR="$ROOT_DIR/src/data/logs"
DEFAULT_PORT=1234  # Порт по умолчанию
ENV_FILE="$ROOT_DIR/src/data/.env" # Переменные окружения
SERVICE_FILE="/etc/supervisord.conf"
VNSTAT_CONF_FILE="/etc/vnstat.conf"
NEW_DATABASE_DIR="$DB_DIR/vnstat"

# Создаем папки
mkdir -p "$DB_DIR"
mkdir -p "$LOGS_DIR"
mkdir -p "$NEW_DATABASE_DIR"

# Автоматические параметры
PORT=${PORT:-$DEFAULT_PORT}
INSTALL_BOT=${INSTALL_BOT:-"Y"}
BOT_TOKEN=${BOT_TOKEN:-""}
ADMIN_ID=${ADMIN_ID:-""}

if [ ! -f "$SERVICE_FILE" ]; then
cat <<EOF | tee $SERVICE_FILE
[supervisord]
user=root
nodaemon=true

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[program:gunicorn]
command=gunicorn -w 4 main:app -b 0.0.0.0:$PORT
directory=$ROOT_DIR
autostart=true
autorestart=true
stdout_logfile=$LOGS_DIR/gunicorn.stdout.log
stderr_logfile=$LOGS_DIR/gunicorn.stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
stdout_logfile_backups=5
stderr_logfile_backups=5

[program:logs]
command=/bin/sh -c "sleep 30 && while true; do /usr/local/bin/python $ROOT_DIR/src/logs.py; sleep 30; done"
directory=$ROOT_DIR/src
autostart=true
autorestart=true
stdout_logfile=$LOGS_DIR/logs.stdout.log
stderr_logfile=$LOGS_DIR/logs.stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
stdout_logfile_backups=5
stderr_logfile_backups=5

EOF

else
echo "SERVICE_FILE существует, пропускаем создание файла."
fi

if [[ "$INSTALL_BOT" =~ ^[Yy]$ ]]; then
cat <<EOF | tee -a $SERVICE_FILE >/dev/null
[program:telegram-bot]
command=/usr/local/bin/python $ROOT_DIR/src/vpn_bot.py
directory=$ROOT_DIR/src
autostart=true
autorestart=true
startretries=3
startsecs=300
restartpause=10
stdout_logfile=$ROOT_DIR/src/data/logs/vpn_bot.stdout.log
stderr_logfile=$ROOT_DIR/src/data/logs/vpn_bot.stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
stdout_logfile_backups=5
stderr_logfile_backups=5
EOF
# Создание .env файла
    if [ ! -f "$ENV_FILE" ]; then
        echo "Creating .env file at $ENV_FILE..."
        cat <<EOF > $ENV_FILE
BOT_TOKEN=$BOT_TOKEN
ADMIN_ID=$ADMIN_ID
EOF
    else
        echo ".env файл существует. Пропускаем создание."
    fi
fi  # Закрытие if для установки Telegram бота

# Меняем пользователя при запуске службы vnstat
sed -i 's/^USER=vnstat/USER=root/' /etc/init.d/vnstat
# Задаем параметр не добавлять все существующие интерфейсы
#sed -i 's|^DAEMON_ARGS=".*"|DAEMON_ARGS="--noadd -d --pidfile \$PIDFILE"|' /etc/init.d/vnstat

# Корректировка файла /etc/vnstat.conf
if [ -f "$VNSTAT_CONF_FILE" ]; then
    echo "Корректировка файла $VNSTAT_CONF_FILE..."
    
    # Указываем логирование в лог-файл и меняем путь к лог-файлу
    sed -i 's|^;\?UseLogging.*|UseLogging 1|' "$VNSTAT_CONF_FILE"
    sed -i "s|^;\?LogFile.*|LogFile \"$ROOT_DIR/src/data/logs/vnstat.log\"|" $VNSTAT_CONF_FILE

    # Заменяем строку с DatabaseDir в конфигурационном файле
    sed -i 's|^;\?DatabaseDir.*|DatabaseDir "'"$NEW_DATABASE_DIR"'"|' "$VNSTAT_CONF_FILE"
    # Указываем не добавлять новые интерфейсы
    sed -i 's|^;\?AlwaysAddNewInterfaces.*|AlwaysAddNewInterfaces 0|' "$VNSTAT_CONF_FILE"  
    echo "Файл $VNSTAT_CONF_FILE успешно скорректирован."
else
    echo "Файл $VNSTAT_CONF_FILE не найден."
fi

#Инициализация базы vnstat для отслеживания заданных интерфейсов
vnstatd --initdb
echo "База инициализирована"
#service vnstat stop

# Получаем список всех сетевых интерфейсов в системе
for iface in $(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1); do
    # Проверяем, соответствует ли имя интерфейса шаблону eth*, ens*
    if [[ "$iface" =~ ^(eth|ens) ]]; then
    # Проверяем, активен ли интерфейс
        # Проверяем, есть ли интерфейс в vnStat
        if ! vnstat --dbiflist | grep -qw "$iface"; then
            echo "Интерфейс $iface не найдет в vnStat. добавляем..."                
            # Добавляем интерфейс в vnStat
            if vnstat --add -i "$iface"; then
                echo "Интерфейс $iface добавлен в vnStat."
            else
                echo "Ошибка добавления $iface в vnStat."
            fi
        else
            echo "Интерфейс $iface уже существует в vnStat."
        fi
    else
        echo "Интерфейс $iface не соответствует паттерну (eth*, ens*). Пропускаем..."
    fi
done

service vnstat start