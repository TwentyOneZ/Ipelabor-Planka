#!/bin/sh
set -eu

SSH_KEY_SOURCE="/run/ssh-keys/ipelabor.key"
SSH_DESTINATION="${SSH_REMOTE_USER:?SSH_REMOTE_USER is required}@${SSH_REMOTE_HOST:?SSH_REMOTE_HOST is required}"
SSH_REVERSE_TUNNEL="${SSH_TUNNEL_REMOTE_PORT:-7002}:${SSH_TUNNEL_TARGET_HOST:-planka}:${SSH_TUNNEL_TARGET_PORT:-1337}"

if [ ! -f "$SSH_KEY_SOURCE" ]; then
  echo "SSH private key not found at $SSH_KEY_SOURCE" >&2
  exit 1
fi

cp "$SSH_KEY_SOURCE" /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

exec ssh \
  -N \
  -R "$SSH_REVERSE_TUNNEL" \
  -i /root/.ssh/id_rsa \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -o ExitOnForwardFailure=yes \
  -p "${SSH_REMOTE_PORT:-22}" \
  "$SSH_DESTINATION"
