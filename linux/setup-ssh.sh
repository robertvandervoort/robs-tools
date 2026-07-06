#!/bin/bash
# setup-ssh.sh - Bootstrap passwordless SSH to one or more hosts.
# For each host: generate a dedicated ed25519 key, add an ~/.ssh/config entry,
# and copy the public key to the remote with ssh-copy-id.

usage() {
    cat << EOF
Usage: $0 [-u <username>] <hostname1> [hostname2 ...]

  -u, --user <username>   Remote username to log in as.
                          Defaults to \$SSH_USER, then the current user (\$USER: $USER).
  -h, --help              Show this help.

Examples:
  $0 server1 server2
  $0 -u admin nas.local
  $0 --user=admin nas.local
  SSH_USER=deploy $0 web01 web02
EOF
}

# Remote username: -u flag > SSH_USER env var > current user.
USERNAME="${SSH_USER:-$USER}"

# Translate long options to their short equivalents so getopts can handle them,
# and reject any unknown --long option with instructions.
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --help)  ARGS+=("-h") ;;
        --user)  ARGS+=("-u") ;;
        --user=*) ARGS+=("-u" "${arg#*=}") ;;
        --*) echo "Error: unknown option '$arg'" >&2; usage >&2; exit 1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

while getopts ":u:h" opt; do
    case "$opt" in
        u) USERNAME="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "Error: invalid option '-$OPTARG'" >&2; usage >&2; exit 1 ;;
        :)  echo "Error: option '-$OPTARG' requires an argument." >&2; usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Require at least one hostname after option parsing.
if [ $# -eq 0 ]; then
    echo "Error: no hostname(s) provided." >&2
    usage >&2
    exit 1
fi

if [ -z "$USERNAME" ]; then
    echo "Error: could not determine a username. Pass one with -u <username>." >&2
    exit 1
fi

SSH_DIR="$HOME/.ssh"
LOCAL_HOST="$(hostname)"

# Ensure SSH directory exists
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Loop through each hostname provided as an argument
for HOST in "$@"; do
    echo "----------------------------------------"
    echo "Processing host: $HOST (user: $USERNAME)"

    # 1. Define key filename based on hostname
    KEY_NAME="id_ed25519_${HOST}"
    KEY_PATH="${SSH_DIR}/${KEY_NAME}"

    # 2. Generate separate SSH keypair if it doesn't exist
    if [ ! -f "$KEY_PATH" ]; then
        echo "Generating new keypair for $HOST..."
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "${USERNAME}@${LOCAL_HOST} for ${HOST}"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to generate key for $HOST. Skipping."
            continue
        fi
    else
        echo "Key already exists for $HOST: $KEY_PATH"
    fi

    # 3. Append to ~/.ssh/config safely (check for duplicates first)
    # We check for "Host <hostname>" to avoid duplicates
    if ! grep -qxF "Host $HOST" "$SSH_DIR/config" 2>/dev/null; then
        echo "Updating SSH config for $HOST..."
        cat >> "$SSH_DIR/config" << EOF

Host $HOST
    HostName $HOST
    User $USERNAME
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
EOF
        echo "Config appended successfully."
    else
        echo "Entry for $HOST already exists in SSH config. Skipping config update."
    fi

    # 4. Run ssh-copy-id interactively
    echo "Running ssh-copy-id for $HOST..."
    # This will prompt you for the password interactively
    ssh-copy-id -i "${KEY_PATH}.pub" "${USERNAME}@${HOST}"

    if [ $? -eq 0 ]; then
        echo "Success: Key copied to $HOST. You can now login with: ssh $HOST"
    else
        echo "Error: Failed to copy key to $HOST."
    fi
done

echo "----------------------------------------"
echo "All done."
