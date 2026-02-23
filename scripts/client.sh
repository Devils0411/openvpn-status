#!/bin/bash
#
# Добавление/удаление клиента
#
# chmod +x client.sh && ./client.sh [1-8] [имя_клиента] [срок_действия]
#
# Срок действия в днях - только для OpenVPN
#
set -e

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Переменные
DIR_OPENVPN=/root/web/openvpn
DIR_PKI=$DIR_OPENVPN/pki
OVPN_FILE_PATH="$DIR_OPENVPN/clients/${CLIENT_NAME}.ovpn"
export LC_ALL=C
export EASYRSA_PKI=$DIR_PKI
EASY_RSA=/usr/share/easy-rsa
INDEX="$DIR_PKI/index.txt"
umask 022

OPTION="$1"
CLIENT_NAME="$2"
export EASYRSA_CERT_EXPIRE=1825
CERT_IP=dynamic.pool

askClientName(){
	if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
		echo
		echo 'Enter client name: 1–32 alphanumeric characters (a-z, A-Z, 0-9) with underscore (_) or dash (-)'
		until [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; do
			read -rp 'Client name: ' -e CLIENT_NAME
		done
	fi
}

render() {
	local IFS=
	while read -r line; do
		while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]]; do
			local LHS="${BASH_REMATCH[1]}"
			local RHS="$(eval echo "\"$LHS\"")"
			line="${line//$LHS/$RHS}"
		done
		echo "$line"
	done < "$1"
}

addOpenVPN(){

# Check if 2FA was specified. If not - set to none.
if [ -z "$TFA_NAME" ]; then
    TFA_NAME="none"
fi

if [[ ! -f $DIR_OPENVPN/clients/$CLIENT_NAME.ovpn ]]; then

export EASYRSA_BATCH=1
#echo 'Патчим easy-rsa.3.1.1 openssl-easyrsa.cnf...' 
sed -i '/serialNumber_default/d' "$EASY_RSA/openssl-easyrsa.cnf"

echo 'Генерируем новый сертификат для клиента'
echo -e "Используем следующие параметры: \nEASYRSA_CERT_EXPIRE: $EASYRSA_CERT_EXPIRE\nEASYRSA_REQ_EMAIL: $EASYRSA_REQ_EMAIL" #\nEASYRSA_REQ_COUNTRY: $EASYRSA_REQ_COUNTRY\nEASYRSA_REQ_PROVINCE: $EASYRSA_REQ_PROVINCE\nEASYRSA_REQ_CITY: 	$EASYRSA_REQ_CITY\nEASYRSA_REQ_ORG: $EASYRSA_REQ_ORG\nEASYRSA_REQ_OU: $EASYRSA_REQ_OU"
echo -e "EasyRSA VARS will be used:\n$(cat $DIR_PKI/vars)"

$EASY_RSA/easyrsa --batch --req-cn="$CLIENT_NAME" --days="$EASYRSA_CERT_EXPIRE" --req-email="$EASYRSA_REQ_EMAIL" gen-req "$CLIENT_NAME" nopass 
#subject="/C=$EASYRSA_REQ_COUNTRY/ST=$EASYRSA_REQ_PROVINCE/L=\"$EASYRSA_REQ_CITY\"/O=\"$EASYRSA_REQ_ORG\"/OU=\"$EASYRSA_REQ_OU\""
        
$EASY_RSA/easyrsa sign-req client "$CLIENT_NAME"
# Fix for /name in index.txt
echo "Правим БД..."
sed -i'.bak' "$ s/$/\/name=${CLIENT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" "$INDEX"
echo "БД скорректирована:"
tail -1 $INDEX
# Certificate properties
CA="$(cat $DIR_PKI/ca.crt )"
CERT="$(awk '/-----BEGIN CERTIFICATE-----/{flag=1;next}/-----END CERTIFICATE-----/{flag=0}flag' $DIR_PKI/issued/${CLIENT_NAME}.crt | tr -d '\0')"
KEY="$(cat $DIR_PKI/private/${CLIENT_NAME}.key)"
TLS_AUTH="$(cat $DIR_PKI/ta.key)"

echo 'Корректируем права доступа к pki/issued...'
chmod +r $DIR_PKI/issued

echo 'Генерация .ovpn файла...'
echo "$(cat $DIR_OPENVPN/config/client.conf)
<ca>
$CA
</ca>
<cert>
$CERT
</cert>
<key>
$KEY
</key>
<tls-auth>
$TLS_AUTH
</tls-auth>
" > "$DIR_OPENVPN/clients/${CLIENT_NAME}.ovpn"

echo -e "Клиентский сертификат успешно сгенерирован!\nПроверь $DIR_OPENVPN/clients/${CLIENT_NAME}.ovpn"

else

CERT_SERIAL=$(grep -E "/name=$CLIENT_NAME/" "$INDEX" | awk '{print $3}')
export EASYRSA_BATCH=1

# Обновление сертификата.
echo "Обновление сертификата: $CLIENT_NAME с $TFA_NAME с локальным IP: $CERT_IP и серийным номером: $CERT_SERIAL"
$EASY_RSA/easyrsa renew "$CLIENT_NAME"
 
# Скорректировать новое /name в index.txt (adding name and ip to the last line)
sed -i'.bak' "$ s/$/\/name=${CLIENT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" $INDEX
echo 'Все готово!'

fi
}

revokeOpenVPN(){

PERSHIY=`cat $INDEX | grep "/CN=$CLIENT_NAME/" | head -1 | awk '{ print $3}'`
CERT_SERIAL=$(grep -E "/name=$CLIENT_NAME/" "$INDEX" | awk '{print $3}')

export EASYRSA_BATCH=1

# Проверяем, если у пользователя 2 сертификата в index.txt
if [[ $(cat $INDEX | grep -c "/CN=$CLIENT_NAME/") -eq 2 ]]; then
    # Проверьте, совпадает ли первый серийный номер с запрошенным для отзыва, и если да, отмените новый сертификат и старый сертификат
    if [[ $PERSHIY = $CERT_SERIAL ]]; then
        echo "Отзыв обновленного сертификата..."

        # Удаляем конец строки, начиная с /name=$NAME, для строки, соответствующей шаблону $serial
        sed  -i'.bak' "/$CERT_SERIAL/s/\/name=$CLIENT_NAME.*//" $INDEX
        echo "index.txt исправлен"
     
        #перемещение нового сертификата в старую директорию
        echo "Выполняется: easyrsa Отзыв обновленного $CLIENT_NAME"
        # Отзыв обновленного сертификата
        $EASY_RSA/easyrsa revoke-renewed "$CLIENT_NAME"
        echo -e "Старый сертификат отозван! \nУдаляем старый сертификат из БД"

        # Удаляем старый сертификат из БД
        sed -i'.bak' "/${CERT_SERIAL}/d" $INDEX
        echo "Старый сертификат с серийным номером $CERT_SERIAL удален из БД"

        # Удаляем *.ovpn файл, потому что сертификат уже не действующий
        echo "Удаляем *.ovpn файл"
        rm -f $OVPN_FILE_PATH
    
        echo 'Генерируем новый .ovpn файл...'
        CA="$(cat $DIR_PKI/ca.crt )"
        CERT="$(cat $DIR_PKI/issued/${CLIENT_NAME}.crt | grep -zEo -e '-----BEGIN CERTIFICATE-----(\n|.)*-----END CERTIFICATE-----' | tr -d '\0')"
        KEY="$(cat $DIR_PKI/private/${CLIENT_NAME}.key)"
        TLS_AUTH="$(cat $DIR_PKI/ta.key)"
        echo "$(cat $DIR_OPENVPN/config/client.conf)
<ca>
$CA
</ca>
<cert>
$CERT
</cert>
<key>
$KEY
</key>
<tls-auth>
$TLS_AUTH
</tls-auth>
" > "$OVPN_FILE_PATH"
        echo -e "Старый сертификат отозван!\nСоздаем новый список отзыва сертификатов (CRL)..."
        $EASY_RSA/easyrsa gen-crl
        chmod +r $DIR_PKI/crl.pem
    else
        # Исправляем index.txt, удалив пользователя из списка по серийному номеру
        echo "Перемещаем новый сертификат..."
        mv $DIR_PKI/renewed/issued/$CLIENT_NAME.crt  $DIR_PKI/issued/$CLIENT_NAME.crt
        rm -f $DIR_PKI/inline/$CLIENT_NAME.inline
        # Удаляем старый сертификат из базы
        sed -i'.bak' "/${CERT_SERIAL}/d" $INDEX
        echo -e "Новый сертификат отозван!\nСоздаем новый список отзыва сертификатов (CRL)..."
        $EASY_RSA/easyrsa gen-crl
        chmod +r $DIR_PKI/crl.pem
    fi
else
    echo "Отзываем сертификат..."
    # Удаляем конец строки, начиная с /name=$NAME, для строки, соответствующей шаблону $serial
    sed  -i'.bak' "/$CERT_SERIAL/s/\/name=$CLIENT_NAME.*//" $INDEX
    # Отзываем сертификат
    $EASY_RSA/easyrsa revoke "$CLIENT_NAME"

    echo 'Создаем новый список отзыва сертификатов (CRL)...'
    $EASY_RSA/easyrsa gen-crl
    chmod +r $DIR_PKI/crl.pem
    # restoring the index.txt, new /name in index.txt (adding name and ip to the last line)
    #sed -i'.bak' "$ s/$/\/name=${CLIENT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" $INDEX
    # Добавляем имя, ip  и 2FA-name в тот же CERT serial
    sed -i'.bak' "/${CERT_SERIAL}/ s/$/\/name=${CLIENT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" $INDEX
fi

echo -e 'Готово!\nЕсли вы хотите отключить пользователя, перезапустите службу с помощью команды: docker-compose restart openvpn.'
}

deleteOpenVPN(){

CERT_SERIAL=$(grep -E "/name=$CLIENT_NAME/" "$INDEX" | awk '{print $3}')
echo "Удаляем пользователя: $CLIENT_NAME с серийным номером: $CERT_SERIAL"

# Определяем, действителен сертификат или отозван
STATUS_CH=$(grep -e ${CLIENT_NAME}$ -e${CLIENT_NAME}/ ${INDEX} | awk '{print $1}' | tr -d '\n')
if [[ $STATUS_CH = "V" ]]; then
    echo "Сертификат действующий\nНе следует удалять: $CLIENT_NAME с серийным номером: $CERT_SERIAL\nВыходим..."
    exit 1
else
    echo "Сертификат отозван\nПродолжаем удаление: $CLIENT_NAME с серийным номером: $CERT_SERIAL"
fi

# Проверяем, если у пользователя 2 сертификата в index.txt
if [[ $(cat $INDEX | grep -c "/CN=$CLIENT_NAME/") -eq 2 ]]; then
    echo "Удаляем обновленного сертификата..."
    sed -i'.bak' "/${CERT_SERIAL}/d" $INDEX
    # Удаляем файл *.ovpn, так как он содержит старый сертификат
    rm -f $OVPN_FILE_PATH
    
    echo 'Генерируем новый .ovpn файл...'
    CA="$(cat $DIR_PKI/ca.crt )"
    CERT="$(cat $DIR_PKI/issued/${CLIENT_NAME}.crt | grep -zEo -e '-----BEGIN CERTIFICATE-----(\n|.)*-----END CERTIFICATE-----' | tr -d '\0')"
    KEY="$(cat $DIR_PKI/private/${CLIENT_NAME}.key)"
    TLS_AUTH="$(cat $DIR_PKI/ta.key)"
    echo "$(cat $OPENVPN_DIR/config/client.conf)
<ca>
$CA
</ca>
<cert>
$CERT
</cert>
<key>
$KEY
</key>
<tls-auth>
$TLS_AUTH
</tls-auth>
" > "$OVPN_FILE_PATH"
    echo "Новый .ovpn файл создан."

else
    echo "Удаляем сертификат...\nУдаляем *.ovpn файл" 
    rm -f $OVPN_FILE_PATH

    # ПРОВЕРКА БЕЗОПАСНОСТИ: Не выполняем, если имя пустое или равно 'ca'
    if [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" != "ca" ]]; then
        # Ищем и удаляем .crt, .key и .req файлы с точным именем клиента
        find "$DIR_PKI" -type f \( -name "${CLIENT_NAME}.crt" -o -name "${CLIENT_NAME}.key" -o -name "${CLIENT_NAME}.req" \) -delete
        echo "Файлы PKI для $CLIENT_NAME удалены."
    else
        echo "ОШИБКА: Неверное имя клиента, пропуск удаления файлов PKI."
    fi

    # Удаляем пользователя из списка по серийному номеру
    sed -i'.bak' "/${CERT_SERIAL}/d" $INDEX
    echo "БД скорректирована."
fi

echo 'Удаление завершено!\nЕсли вы хотите отключить пользователя, перезапустите службу с помощью команды: docker-compose restart openvpn.'

}

listOpenVPN(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'OpenVPN client names:'
	ls $DIR_OPENVPN/clients | sed 's/\.ovpn$//' | grep -v "^antizapret-server$" | sort
}


if ! [[ "$OPTION" =~ ^[1-3]$ ]]; then
	echo
	echo 'Please choose option:'
	echo '    1) OpenVPN - Добавление/Обновление сертификата клиента'
	echo '    2) OpenVPN - Удаление клиента'
	echo '    3) OpenVPN - список склиентов'
	until [[ "$OPTION" =~ ^[1-3]$ ]]; do
		read -rp 'Option choice [1-3]: ' -e OPTION
	done
fi

case "$OPTION" in
	1)
		echo "OpenVPN - Добавление/Обновление сертификата клиента $CLIENT_NAME"
		askClientName
		addOpenVPN
		;;
	2)
		echo "OpenVPN - Удаление клиента $CLIENT_NAME"
		listOpenVPN
		askClientName
                revokeOpenVPN
		deleteOpenVPN
		;;
	3)
		echo 'OpenVPN - List clients'
		listOpenVPN
		;;
esac
exit 0