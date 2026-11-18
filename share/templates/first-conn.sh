# first-conn.sh template - rendered locally and run as root on the target.
# Creates the two accounts, installs the installer key and prepares $ROOT.
set -eu

admin=@ADMIN_USER@
worker=@WORKER_USER@
root=@ROOT@
pubkey=@PUBLIC_KEY@

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'first-conn: root is required\n' >&2
  exit 1
fi

add_user() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
  fi
}

user_home() {
  local user="$1" line
  local -a fields
  line="$(getent passwd "$user")" || return 1
  IFS=: read -r -a fields <<<"$line"
  [[ -n "${fields[5]:-}" ]] || return 1
  printf '%s\n' "${fields[5]}"
}

add_to_group() {
  local user="$1" group="$2"
  getent group "$group" >/dev/null 2>&1 || return 1
  usermod -aG "$group" "$user"
}

add_user "$admin"
add_user "$worker"

if [[ -z "$root" ]]; then
  admin_home="$(user_home "$admin" || true)"
  [[ -n "$admin_home" ]] || {
    printf 'first-conn: cannot determine the home directory of %s\n' "$admin" >&2
    exit 1
  }
  root="$admin_home/.beaut"
fi
[[ -n "$root" ]] || {
  printf 'first-conn: cannot determine the install root\n' >&2
  exit 1
}

add_to_group "$admin" sudo || add_to_group "$admin" wheel || true
add_to_group "$admin" docker || true
add_to_group "$worker" docker || true

key_exists() {
  local file="$1" line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$pubkey" ]] && return 0
  done <"$file"
  return 1
}

install_key() {
  local user="$1" home keyfile
  home="$(user_home "$user" || true)"
  [[ -n "$home" ]] || {
    printf 'first-conn: cannot determine the home directory of %s\n' "$user" >&2
    exit 1
  }
  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  keyfile="$home/.ssh/authorized_keys"
  touch "$keyfile"
  chown "$user:$user" "$keyfile"
  chmod 600 "$keyfile"
  if ! key_exists "$keyfile"; then
    printf '%s\n' "$pubkey" >>"$keyfile"
  fi
}

install_key "$admin"
install_key "$worker"

sudoers=/etc/sudoers.d/beaut-worker
docker_bin="$(command -v docker 2>/dev/null || printf /usr/bin/docker)"
apt_bin="$(command -v apt-get 2>/dev/null || printf /usr/bin/apt-get)"
# The admin runs the deployed user units for now, so it needs non-interactive
# Docker too. The worker account is ready for the later per-worker units.
printf '%s\n' \
  "$worker ALL=(root) NOPASSWD: $docker_bin" \
  "$worker ALL=(root) NOPASSWD: $apt_bin" \
  "$admin ALL=(root) NOPASSWD: $docker_bin" >"$sudoers"
chmod 440 "$sudoers"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$sudoers" >/dev/null || {
    rm -f "$sudoers"
    printf 'first-conn: invalid sudoers entry\n' >&2
    exit 1
  }
fi

install -d -m 755 "$root"
for dir in app state logs containers snapshots conf repos; do
  install -d -m 755 "$root/$dir"
done
install -d -m 700 "$root/conf/keys" "$root/conf/workers"
chown -R "$admin" "$root"

if ! command -v docker >/dev/null 2>&1; then
  printf 'first-conn: warning: docker is not installed\n' >&2
fi
if ! command -v socat >/dev/null 2>&1; then
  printf 'first-conn: warning: socat is not installed\n' >&2
fi

printf 'first-conn: users and directories ready on %s\n' "${HOSTNAME:-$(hostname)}"
