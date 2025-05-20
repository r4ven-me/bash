#!/bin/bash

set -Eeuo pipefail

OCSERV_DIR="/etc/ocserv"
SECRETS_DIR="/etc/ocserv/secrets"
SCRIPTS_DIR="/etc/ocserv/scripts"
OTP_SEND_BY_EMAIL="true"
OTP_SEND_BY_TELEGRAM="true"
TG_TOKEN="1234567890:QWERTYuio-PA1DFGHJ2_KlzxcVBNmqWEr3t"

echo "[$(date '+%F %T')] - PAM user $PAM_USER is trying to connect to ocserv" >> "${OCSERV_DIR}"/pam.log

otp_sender_by_email() {
    EMAIL_REGEX="^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    if [[ $PAM_USER =~ $EMAIL_REGEX ]]; then true; else return 0; fi

    if [[ -e "${SECRETS_DIR}"/users.oath ]] && grep -qP "(?<!\S)${PAM_USER}(?!\S)" "${SECRETS_DIR}"/users.oath; then
        OTP_TOKEN="$(oathtool --totp=SHA1 --time-step-size=30 --digits=6 $(grep -P "(?<!\S)${PAM_USER}(?!\S)" ${SECRETS_DIR}/users.oath | awk '{print $4}'))"

        echo -e "Subject: TOTP token for OpenConnect\n\n${OTP_TOKEN}" | msmtp --file="${SCRIPTS_DIR}"/msmtprc "$PAM_USER"
        echo "[$(date '+%F %T')] - TOTP token successfully sent to $PAM_USER" >> "${OCSERV_DIR}"/pam.log
    fi
}

otp_sender_by_telegram() {
    TG_REGEX="^[a-zA-Z][a-zA-Z0-9_]{4,31}$"
    if [[ $PAM_USER =~ $TG_REGEX ]]; then true; else return 0; fi

    if grep -qP "(?<!\S)${PAM_USER}(?!\S)" "${SECRETS_DIR}"/users.oath 2> /dev/null; then
        OTP_TOKEN="$(oathtool --totp=SHA1 --time-step-size=30 --digits=6 $(grep -P "(?<!\S)${PAM_USER}(?!\S)" ${SECRETS_DIR}/users.oath | awk '{print $4}'))"
        TG_MESSAGE="TOTP token for OpenConnect: $OTP_TOKEN"
        TG_USER_FILE="${SCRIPTS_DIR}/tg_users.txt"
        
        if grep -qP "(?<!\S)$PAM_USER(?!\S)" "$TG_USER_FILE" 2> /dev/null; then
            TG_CHAT_ID=$(grep -P "(?<!\S)${PAM_USER}(?!\S)" "$TG_USER_FILE" | awk '{print $1}')
        else
            TG_RESPONSE="$(curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates")"
            TG_CHAT_ID=$(echo "$TG_RESPONSE" | jq -r --arg USERNAME "$PAM_USER" '.result[] | select(.message.from.username == $USERNAME) | .message.chat.id')
    
            if [[ -z "$TG_CHAT_ID" ]]; then
                echo "[$(date '+%F %T')] - User was not found or did not interact with the bot" >> "${OCSERV_DIR}"/pam.log
                return 0
            fi
            echo "$TG_CHAT_ID $PAM_USER" >> "$TG_USER_FILE"
        fi  
        
        curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$TG_MESSAGE" 2>> "${OCSERV_DIR}"/pam.log
        echo "[$(date '+%F %T')] - TOTP token successfully sent to $PAM_USER" >> "${OCSERV_DIR}"/pam.log
    fi
}

if [[ "$OTP_SEND_BY_EMAIL" == "true" ]]; then otp_sender_by_email; fi &

if [[ "$OTP_SEND_BY_TELEGRAM" == "true" ]]; then otp_sender_by_telegram; fi &

