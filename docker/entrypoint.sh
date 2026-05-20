#!/bin/sh
# Image entrypoint.
#
# Most invocations pass through to the limousine server. One side-channel
# subcommand: `export-limousine-script` prints the bundled wrapper script to
# stdout, so a teammate can drop the wrapper onto their host with a single
# docker invocation (no GitHub round-trip needed):
#
#   docker run --rm ghcr.io/pattern-agentic/limousine:latest \
#       export-limousine-script > limousine && chmod +x limousine
#
# Before exec'ing the server we synthesise a /etc/passwd entry for the
# running uid via nss_wrapper, so tools that call getpwuid() (ssh, git, npm,
# etc.) can resolve the user. Needed because docker is launched with
# `--user <host-uid>:<host-gid>` and the base image only ships entries for a
# fixed set of uids — macOS users (uid 501) are the common case.

set -e

# -- side-channel subcommands ----------------------------------------------

case "${1:-}" in
  export-limousine-script)
    exec cat /opt/limousine/scripts/limousine
    ;;
esac

# -- main server path ------------------------------------------------------

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
