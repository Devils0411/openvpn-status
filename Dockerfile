# Базовый образ Python
FROM python:3.10-slim

# Установка зависимостей системы
RUN apt-get update && apt-get install -y \
    curl \
    vnstat \
    procps \
    easy-rsa \
    iproute2 \
    supervisor && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && chmod 755 /usr/share/easy-rsa/*

# Создание рабочей директории
WORKDIR /root/web

# Создание необходимой поддиректории logs
RUN mkdir -p src/data/logs && mkdir -p src/data/databases && mkdir -p openvpn

# Копирование файлов проекта
COPY scripts/ ./scripts/
COPY src/ ./src/
COPY static/ ./static/
COPY templates/ ./templates/
COPY main.py requirements.txt ./
COPY files/ /usr/share/easy-rsa/

# Установка Python зависимостей
RUN pip install --no-cache-dir -r requirements.txt

# Сделать файлы в папках исполняемыми
RUN chmod +x ./scripts/* && chmod +x ./src/*

# Запуск приложения
ENTRYPOINT ["./scripts/entrypoint.sh"]