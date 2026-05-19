#!/bin/sh
# Synthesise a /etc/passwd entry for the running uid via nss_wrapper, so tools
# that call getpwuid() (ssh, git, npm, etc.) can resolve the user. Needed
# because docker is launched with `--user <host-uid>:<host-gid>` and the base
# image only ships entries for a fixed set of uids. macOS users (uid 501) are
# the common case; Linux users with uid 1000 accidentally match the base
# image's `ubuntu` user and don't notice.

set -e

if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  TMP_PASSWD="$(mktemp)"
  TMP_GROUP="$(mktemp)"
  cp /etc/passwd "$TMP_PASSWD"
  cp /etc/group  "$TMP_GROUP"

  uid="$(id -u)"
  gid="$(id -g)"
  home="${HOME:-/tmp}"

  printf 'limousine:x:%s:%s:Limousine:%s:/bin/bash\n' "$uid" "$gid" "$home" >> "$TMP_PASSWD"
  if ! getent group "$gid" >/dev/null 2>&1; then
    printf 'limousine:x:%s:\n' "$gid" >> "$TMP_GROUP"
  fi

  # Make the wrap inheritable by every child the limousine server spawns
  # (git, ssh, kubectl, npm, uv, …) so they all see the synthesised entry.
  export LD_PRELOAD=libnss_wrapper.so
  export NSS_WRAPPER_PASSWD="$TMP_PASSWD"
  export NSS_WRAPPER_GROUP="$TMP_GROUP"
fi

exec /opt/limousine/limousine-server --web-root /opt/limousine/web "$@"
