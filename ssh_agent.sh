#!/usr/bin/env bash

# Set system PATH
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Add this line to your session .*rc file:
# if [[ -f "$HOME/.ssh/environment" ]]; then source $HOME/.ssh/environment; fi

# Enable strict mode
set -euo pipefail

# Initialize common variables
IFS=$'\n\t'
SSH_ENV="$HOME/.ssh/environment"
UTILS=("ssh-agent" "ssh-add" "ssh-keygen" "expect" "secret-tool")

# Verify required utilities exist
for util in "${UTILS[@]}"; do 
    if ! which "$util" > /dev/null; then
        echo "$util not found or not installed"
        exit 1
    fi
done

# SSH key loading function with expect automation
ssh_add() {
    local key="$1"
    local pass="$2"

    if ! expect << EOF
spawn ssh-add $key
expect "Enter passphrase for $key"
send -- "$pass\r"
expect {
    "Bad passphrase" {
        exit 1
    }
    "Identity added" {
        exit 0
    }
    eof
}
EOF
    then
        return 1
    fi
    return 0
}

# Main key loading logic
load_keys() {
    echo "Loading SSH keys..."

    local pass
    local keys
    readarray -t keys < <(find "$HOME/.ssh" -type f \( \
        -name 'id_rsa*' -o -name 'id_dsa*' -o \
        -name 'id_ecdsa*' -o -name 'id_ed25519*' \
        \) ! -name '*.pub')

    for key in "${keys[@]}"; do
        if ! ssh-keygen -y -P "" -f "$key" &> /dev/null; then
            if pass=$(secret-tool lookup unique ssh-store:"${key}"); then
                ssh_add "$key" "$pass" &> /dev/null && echo "Loaded: $key" || echo "Failed to load: $key"
            else
                echo "Failed to get passphrase for $key"
                if [[ -t 0 ]]; then
                    echo "Let's add it to keyring:"
                    secret-tool store --label="$(basename "$key")" unique ssh-store:"${key}" 
                    pass=$(secret-tool lookup unique ssh-store:"${key}")
                    ssh_add "$key" "$pass" &> /dev/null && echo "Loaded: $key" || echo "Failed to load: $key"
                fi
            fi

        else
            ssh-add "$key" &> /dev/null && echo "Loaded: $key" || echo "Failed to load: $key"
        fi
    done
}

# SSH agent initialization
start_agent() {
    echo "Initializing new SSH agent..."
    ssh-agent | sed 's/^echo/#echo/' > "$SSH_ENV"
    chmod 600 "$SSH_ENV"
    # shellcheck disable=SC1090
    source "$SSH_ENV" > /dev/null
    echo "SSH agent started successfully."
    load_keys
}

# Agent process check
is_agent_running() {
    if [[ -n "${SSH_AGENT_PID:-}" ]]; then
        ps -p "$SSH_AGENT_PID" -o comm= 2>/dev/null | grep -q '^ssh-agent$'
    else
        return 1
    fi
}

# Main execution flow
if [[ -f "$SSH_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$SSH_ENV" > /dev/null

    if ! is_agent_running; then
        echo "Stale SSH agent found. Restarting..."
        start_agent
    fi
else
    start_agent
fi
