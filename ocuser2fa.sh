#!/bin/bash

set -Eeuo pipefail

OCSERV_DIR="/etc/ocserv"
SECRETS_DIR="/etc/ocserv/secrets"
SCRIPTS_DIR="/etc/ocserv/scripts"
OTP_SEND_BY_EMAIL="true"
OTP_SEND_BY_TELEGRAM="true"
TG_TOKEN="1234567890:QWERTYuio-PA1DFGHJ2_KlzxcVBNmqWEr3t"

if [[ $# -eq 1 ]]; then
    USER_ID="$1"
    OTP_SECRET="$(head -c 16 /dev/urandom | xxd -c 256 -ps)"
    OTP_SECRET_BASE32="$(echo 0x"${OTP_SECRET}" | xxd -r -c 256 | base32)"
    OTP_SECRET_QR="otpauth://totp/$USER_ID?secret=$OTP_SECRET_BASE32&issuer=COMPANY&algorithm=SHA1&digits=6&period=30"

    if [[ ! -e "${SECRETS_DIR}"/users.oath ]] || ! grep -qP "(?<!\S)${USER_ID}(?!\S)" "${SECRETS_DIR}"/users.oath; then
        echo "HOTP/T30 $USER_ID - $OTP_SECRET" >> "${SECRETS_DIR}"/users.oath
        echo "OTP secret for $USER_ID: $OTP_SECRET"
        echo "OTP secret in base32: $OTP_SECRET_BASE32"
        echo "OTP secret in QR code:"
        qrencode -t ANSIUTF8 "$OTP_SECRET_QR"
        qrencode "$OTP_SECRET_QR" -s 10 -o "${SECRETS_DIR}"/otp_"${USER_ID}".png
        echo "TOTP secret in png image saved at: ${SECRETS_DIR}/otp_${USER_ID}.png"

        send_qr_by_email() {
            EMAIL_REGEX="^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"

            if [[ $USER_ID =~ $EMAIL_REGEX ]]; then
                cat << EOF | msmtp --file="${SCRIPTS_DIR}"/msmtprc "$USER_ID"
Subject: TOTP QR code for OpenConnect auth
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="boundary"

--boundary
Content-Type: text/plain

TOTP secret for OpenConnect (base32):
$OTP_SECRET_BASE32

--boundary
Content-Type: image/png; name="file.png"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="file.png"

$(base64 "${SECRETS_DIR}"/otp_"${USER_ID}".png)
--boundary--
EOF
                echo "[$(date '+%F %T')] - TOTP secret and QR code successfully sent to $USER_ID via Email" | tee -a "${OCSERV_DIR}"/pam.log
            else
                return 0
            fi
        }

        if [[ "$OTP_SEND_BY_EMAIL" == "true" ]]; then send_qr_by_email; fi

        send_qr_by_telegram() {
            TG_REGEX="^[a-zA-Z][a-zA-Z0-9_]{4,31}$"

            if [[ $USER_ID =~ $TG_REGEX ]]; then
                TG_MESSAGE="TOTP secret for OpenConnect (base32):
$OTP_SECRET_BASE32"
                TG_USER_FILE="${SCRIPTS_DIR}/tg_users.txt"
                
                if grep -qP "(?<!\S)${USER_ID}(?!\S)" "$TG_USER_FILE" 2> /dev/null; then
                    TG_CHAT_ID=$(grep -P "(?<!\S)${USER_ID}(?!\S)" "$TG_USER_FILE" | awk '{print $1}')
                else
                    TG_RESPONSE="$(curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates")"
                    TG_CHAT_ID=$(echo "$TG_RESPONSE" | jq -r --arg USERNAME "$USER_ID" '.result[] | select(.message.from.username == $USERNAME) | .message.chat.id')

                    if [[ -z "$TG_CHAT_ID" ]]; then
                        echo "[$(date '+%F %T')] - User was not found or did not interact with the bot" >> "${OCSERV_DIR}"/pam.log
                        return 0
                    fi
                    echo "$TG_CHAT_ID $USER_ID" >> "$TG_USER_FILE"
                fi

                curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendPhoto" \
                    -H "Content-Type: multipart/form-data" \
                    -F "chat_id=$TG_CHAT_ID" \
                    -F "photo=@${SECRETS_DIR}/otp_${USER_ID}.png" \
                    -F "caption=$TG_MESSAGE" > /dev/null 2>> "${OCSERV_DIR}"/pam.log

                echo "[$(date '+%F %T')] - TOTP secret and QR code successfully sent to $USER_ID via Telegram" | tee -a "${OCSERV_DIR}"/pam.log
            fi
        }

        if [[ "$OTP_SEND_BY_TELEGRAM" == "true" ]]; then send_qr_by_telegram; fi

    else
        echo "OTP token already exists for $USER_ID in ${SECRETS_DIR}/users.oath"
        exit 1
    fi
else
    echo "Usage: $(basename "$0") <user_id>"
    exit 1
fi

