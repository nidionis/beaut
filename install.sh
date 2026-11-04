#!/usr/bin/env bash
# install.sh — one-command bootstrap for beaut.
#
#   sudo ./install.sh --roles hub --domain beaut.example.org     # system install
#   ./install.sh --user --roles client                            # per-user install
#
# System install: /usr/local/share/beaut/{bin,lib,docs}, /usr/local/bin/beaut,
# /etc/beaut/config.env (root:beaut 0640 — root edits, the service reads),
# `beaut` system user owning /var/lib/beaut, beaut.service enabled+started.
# User install:   ~/.local/share/beaut, ~/.local/bin/beaut, ~/.config/beaut/config.env,
# systemd --user unit. Re-running is idempotent; an existing config.env is kept.
#
# For tests the system layout can be redirected without touching the host:
#   BEAUT_INSTALL_CONF_DIR, BEAUT_INSTALL_STATE_DIR, BEAUT_INSTALL_UNIT_DIR,
#   BEAUT_INSTALL_USER (service account; defaults to beaut).
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BEAUT_ROOT="$SRC"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

usage() {
    cat <<EOF
usage: install.sh [--roles hub,worker,client] [--domain NAME] [--user]
                  [--admin-port N] [--tunnel-user NAME] [--tunnel-port N]
                  [--prefix DIR] [--no-service] [--no-sshd] [--deps] [--uninstall]

  --roles LIST     roles for this host (default: client)
  --domain NAME    hub domain written to config.env (default: localhost; [A-Za-z0-9.-])
  --admin-port N   hub HTTP port (default: 8888)
  --tunnel-user NAME
                   hub account workers connect to (default: tunnel)
  --tunnel-port N  hub sshd port (default: 22)
  --user           install for the current user only (no root, systemd --user)
  --prefix DIR     install prefix (default: /usr/local, or ~/.local with --user)
  --no-service     do not install/enable the systemd unit
  --no-sshd        do not configure sshd for the tunnel account (hub only)
  --deps           also try to install dependencies with the system package manager
  --uninstall      remove installed files and the unit (config and state are kept)
EOF
}

ROLES_ARG="client"; DOMAIN_ARG="localhost"; ADMIN_PORT_ARG=8888
TUNNEL_USER_ARG="tunnel"; TUNNEL_PORT_ARG=22
USER_MODE=0; PREFIX=""; SERVICE=1; SSHD=1; DEPS=0; UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --roles)   ROLES_ARG="$2"; shift 2 ;;
        --domain)  DOMAIN_ARG="$2"; shift 2 ;;
        --admin-port)   ADMIN_PORT_ARG="$2"; shift 2 ;;
        --tunnel-user)  TUNNEL_USER_ARG="$2"; shift 2 ;;
        --tunnel-port)  TUNNEL_PORT_ARG="$2"; shift 2 ;;
        --user)    USER_MODE=1; shift ;;
        --prefix)  PREFIX="$2"; shift 2 ;;
        --no-service) SERVICE=0; shift ;;
        --no-sshd) SSHD=0; shift ;;
        --deps)    DEPS=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [ "$USER_MODE" = 1 ]; then
    PREFIX="${PREFIX:-$HOME/.local}"
    CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/beaut"
    STATE="${XDG_STATE_HOME:-$HOME/.local/state}/beaut"
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    SSHD_DIR=""
    SYSTEMCTL="systemctl --user"
    SVC_USER="$(id -un)"
else
    [ "$(id -u)" = 0 ] || die "system install needs root (or use --user)"
    PREFIX="${PREFIX:-/usr/local}"
    CONF_DIR="${BEAUT_INSTALL_CONF_DIR:-/etc/beaut}"
    STATE="${BEAUT_INSTALL_STATE_DIR:-/var/lib/beaut}"
    UNIT_DIR="${BEAUT_INSTALL_UNIT_DIR:-/etc/systemd/system}"
    SSHD_DIR="${BEAUT_INSTALL_SSHD_DIR:-/etc/ssh/sshd_config.d}"
    SYSTEMCTL="systemctl"
    SVC_USER="${BEAUT_INSTALL_USER:-beaut}"
fi
SHARE="$PREFIX/share/beaut"
BIN="$PREFIX/bin"

# Validate inputs before they reach the config (which is sourced as bash).
for r in ${ROLES_ARG//,/ }; do
    case "$r" in hub|worker|client) ;; *) die "unknown role: $r" ;; esac
done
[[ "$DOMAIN_ARG" =~ ^[A-Za-z0-9.-]+$ ]] || die "--domain may only contain [A-Za-z0-9.-]: '$DOMAIN_ARG'"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid service user name: $SVC_USER"
[[ "$TUNNEL_USER_ARG" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid tunnel user name: $TUNNEL_USER_ARG"
is_port "$ADMIN_PORT_ARG" || die "--admin-port must be 1..65535"
is_port "$TUNNEL_PORT_ARG" || die "--tunnel-port must be 1..65535"
case "$STATE$PREFIX$CONF_DIR" in
    *[\"\$\`\\]*|*$'\n'*) die "paths must not contain quotes, \$, backticks, backslashes or newlines" ;;
esac
[[ "$STATE" = /* ]] && [[ "$PREFIX" = /* ]] && [[ "$CONF_DIR" = /* ]] || die "paths must be absolute"

if [ "$UNINSTALL" = 1 ]; then
    if [ "$SERVICE" = 1 ] && have systemctl; then
        $SYSTEMCTL disable --now beaut.service 2>/dev/null || true
        rm -f "$UNIT_DIR/beaut.service"; $SYSTEMCTL daemon-reload 2>/dev/null || true
    fi
    if [ -n "$SSHD_DIR" ] && [ -f "$SSHD_DIR/beaut.conf" ]; then
        rm -f "$SSHD_DIR/beaut.conf"
        have systemctl && { systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; }
    fi
    rm -rf "${SHARE:?}"; rm -f "${BIN:?}/beaut"
    info "removed $SHARE and $BIN/beaut (kept $CONF_DIR and $STATE)"
    exit 0
fi

# ---- dependencies -----------------------------------------------------------
role_deps() {
    local d="bash curl tar ssh ssh-keygen"
    case " ${ROLES_ARG//,/ } " in *" hub "*)    d="$d socat sshd" ;; esac
    case " ${ROLES_ARG//,/ } " in *" worker "*) d="$d autossh sshd" ;; esac
    printf '%s\n' "$d"
}
# role_pkgs — distro package names for the tools role_deps needs
role_pkgs() {
    local p="curl tar" ssh_client="openssh-client" ssh_server="openssh-server"
    if have apk || have pacman; then ssh_client="openssh"; ssh_server="openssh"; fi
    if have dnf; then ssh_client="openssh-clients"; fi
    p="$p $ssh_client"
    case " ${ROLES_ARG//,/ } " in *" hub "*)    p="$p socat $ssh_server" ;; esac
    case " ${ROLES_ARG//,/ } " in *" worker "*) p="$p autossh $ssh_server" ;; esac
    printf '%s\n' "$p"
}
if [ "$DEPS" = 1 ]; then
    if [ "$USER_MODE" = 1 ]; then
        warn "--deps needs root; skipping in --user mode"
    else
        pk=""
        if   have apt-get; then apt-get update -qq || true; pk="apt-get install -y -qq"
        elif have dnf;     then pk="dnf install -y"
        elif have pacman;  then pk="pacman -S --noconfirm --needed"
        elif have apk;     then pk="apk add"
        fi
        if [ -n "$pk" ]; then
            info "installing packages for roles '$ROLES_ARG': $(role_pkgs)"
            # shellcheck disable=SC2046
            $pk $(role_pkgs) || warn "dependency install failed, continuing"
        else
            warn "no known package manager, skipping --deps"
        fi
    fi
fi
missing=""
for c in $(role_deps); do have "$c" || missing="$missing $c"; done
[ -z "$missing" ] || warn "missing tools for roles '$ROLES_ARG':$missing (re-run with --deps or install them)"

# ---- files ------------------------------------------------------------------
umask 022
mkdir -p "$SHARE" "$BIN"
rm -rf "${SHARE:?}/bin" "${SHARE:?}/lib" "${SHARE:?}/docs"
cp -r "$SRC/bin" "$SRC/lib" "$SHARE/"
[ -d "$SRC/docs" ] && cp -r "$SRC/docs" "$SHARE/"
cp "$SRC/config.env.example" "$SHARE/config.env.example"
chmod 755 "$SHARE/bin/beaut"
ln -sfn "$SHARE/bin/beaut" "$BIN/beaut"
info "installed $SHARE, $BIN/beaut"

# ---- service user + state ------------------------------------------------------
# A worker must accept an inbound ssh command from the hub, so its account needs
# a usable login shell; a hub-only account stays nologin.
LOGIN_SHELL=/usr/sbin/nologin
case ",$ROLES_ARG," in *,worker,*) LOGIN_SHELL=/bin/sh ;; esac
if [ "$USER_MODE" = 0 ]; then
    if ! getent group "$SVC_USER" >/dev/null 2>&1; then
        if have groupadd; then
            groupadd --system "$SVC_USER"
        elif have addgroup; then
            # BusyBox/Alpine uses addgroup -S for a system group.
            addgroup -S "$SVC_USER"
        else
            die "cannot create group $SVC_USER (no groupadd/addgroup)"
        fi
    fi
    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        if have useradd; then useradd --system --gid "$SVC_USER" --home-dir "$STATE" --shell "$LOGIN_SHELL" "$SVC_USER"
        elif have adduser; then adduser -S -D -H -h "$STATE" -s "$LOGIN_SHELL" -G "$SVC_USER" "$SVC_USER"
        else die "cannot create user $SVC_USER (no useradd/adduser)"; fi
        info "created system user $SVC_USER"
    elif [ "$LOGIN_SHELL" = /bin/sh ] && [ "$SVC_USER" != root ] && have usermod; then
        usermod -s /bin/sh "$SVC_USER" 2>/dev/null || true
    fi
fi
mkdir -p "$STATE"; chmod 700 "$STATE"
[ "$USER_MODE" = 1 ] || chown "$SVC_USER:$SVC_USER" "$STATE"

# ---- config ------------------------------------------------------------------
# render_config — example with DOMAIN/ROLES/STATE_DIR replaced, line by line
# (values were validated above, so they are safe inside double quotes).
render_config() {
    local line
    while IFS= read -r line; do
        case "$line" in
            DOMAIN=*)       printf 'DOMAIN="%s"%s\n'       "$DOMAIN_ARG" "${line#*\"*\"}" ;;
            ROLES=*)        printf 'ROLES="%s"%s\n'        "$ROLES_ARG"  "${line#*\"*\"}" ;;
            STATE_DIR=*)    printf 'STATE_DIR="%s"%s\n'    "$STATE"      "${line#*\"*\"}" ;;
            ADMIN_PORT=*)   printf 'ADMIN_PORT=%s\n'       "$ADMIN_PORT_ARG" ;;
            TUNNEL_USER=*)  printf 'TUNNEL_USER="%s"%s\n'  "$TUNNEL_USER_ARG" "${line#*\"*\"}" ;;
            TUNNEL_PORT=*)  printf 'TUNNEL_PORT=%s\n'      "$TUNNEL_PORT_ARG" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$SRC/config.env.example"
}
mkdir -p "$CONF_DIR"
if [ -e "$CONF_DIR/config.env" ]; then
    info "keeping existing $CONF_DIR/config.env"
else
    umask 077
    render_config > "$CONF_DIR/config.env"
    umask 022
    info "wrote $CONF_DIR/config.env (roles=$ROLES_ARG domain=$DOMAIN_ARG)"
fi
if [ "$USER_MODE" = 1 ]; then
    chmod 700 "$CONF_DIR"; chmod 600 "$CONF_DIR/config.env"
else
    # root owns the config (it is sourced as code; the service must not be able
    # to rewrite it); the service group may read it. Root and the service user
    # therefore both pass beaut's ownership check.
    chown "root:$SVC_USER" "$CONF_DIR" "$CONF_DIR/config.env"
    chmod 750 "$CONF_DIR"; chmod 640 "$CONF_DIR/config.env"
fi

# ---- sanity: root (admin CLI) and the service user must both load the config ----
BEAUT_CONFIG="$CONF_DIR/config.env" "$BIN/beaut" roles >/dev/null \
    || die "installed beaut failed to load config as $(id -un)"
if [ "$USER_MODE" = 0 ] && [ "$SVC_USER" != "$(id -un)" ]; then
    if have runuser; then
        runuser -u "$SVC_USER" -- env BEAUT_CONFIG="$CONF_DIR/config.env" "$BIN/beaut" status >/dev/null \
            || die "service user $SVC_USER cannot load config/state ($CONF_DIR, $STATE)"
    elif have su; then
        su -s /bin/sh "$SVC_USER" -c "BEAUT_CONFIG='$CONF_DIR/config.env' '$BIN/beaut' status" >/dev/null \
            || die "service user $SVC_USER cannot load config/state ($CONF_DIR, $STATE)"
    else
        warn "no runuser/su: skipped service-user config check"
    fi
fi

# ---- sshd: tunnel account ------------------------------------------------------
# Workers authenticate with a key registered at /register. sshd asks
# `beaut __authorized-keys` for the tunnel account's keys, so the hub never has
# to rewrite a root-owned authorized_keys file.
WANT_SSHD=0
case ",$ROLES_ARG," in
    *,hub,*) if [ "$USER_MODE" = 0 ] && [ "$SERVICE" = 1 ] && [ "$SSHD" = 1 ]; then WANT_SSHD=1; fi ;;
esac
if [ "$WANT_SSHD" = 1 ]; then
    if [ "$SVC_USER" = root ]; then
        warn "refusing AuthorizedKeysCommandUser=root; not configuring sshd"
    elif ! have sshd; then
        warn "sshd not found; not configuring the tunnel account"
    else
        if ! getent group "$TUNNEL_USER_ARG" >/dev/null 2>&1; then
            have groupadd && groupadd --system "$TUNNEL_USER_ARG" || true
        fi
        if ! id -u "$TUNNEL_USER_ARG" >/dev/null 2>&1; then
            if have useradd; then
                useradd --system --gid "$TUNNEL_USER_ARG" --home-dir /nonexistent \
                    --no-create-home --shell /usr/sbin/nologin "$TUNNEL_USER_ARG" 2>/dev/null || true
            elif have adduser; then
                adduser -S -D -H -h /nonexistent -s /sbin/nologin -G "$TUNNEL_USER_ARG" "$TUNNEL_USER_ARG" 2>/dev/null || true
            fi
        fi
        mkdir -p "$SSHD_DIR"
        cat > "$SSHD_DIR/beaut.conf" <<EOF
# managed by beaut install.sh
Match User $TUNNEL_USER_ARG
    AuthorizedKeysFile none
    AuthorizedKeysCommand $BIN/beaut __authorized-keys %u %f
    AuthorizedKeysCommandUser $SVC_USER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
EOF
        if ! sshd -t >/dev/null 2>&1; then
            rm -f "$SSHD_DIR/beaut.conf"
            warn "sshd rejected the beaut drop-in; removed it (check $SSHD_DIR)"
        else
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            info "configured sshd tunnel account '$TUNNEL_USER_ARG'"
        fi
    fi
fi

# ---- systemd -----------------------------------------------------------------
if [ "$SERVICE" = 1 ]; then
    if ! have systemctl; then
        warn "systemd not found: start '$BIN/beaut daemon' with your init of choice"
    else
        mkdir -p "$UNIT_DIR"
        sed -e "s|^Environment=BEAUT_CONFIG=.*|Environment=BEAUT_CONFIG=$CONF_DIR/config.env|" \
            -e "s|^ExecStart=.*|ExecStart=$BIN/beaut daemon|" \
            -e "s|^ReadWritePaths=.*|ReadWritePaths=$STATE|" \
            -e "s|^Documentation=.*|Documentation=file://$SHARE/docs/architecture.md|" \
            "$SRC/beaut.service" > "$UNIT_DIR/beaut.service"
        if [ "$USER_MODE" = 1 ]; then
            # per-user units cannot switch user or use system state dirs
            sed -i -e '/^User=/d' -e '/^Group=/d' -e '/^StateDirectory/d' -e '/^ConfigurationDirectory/d' \
                -e '/^ProtectHome=/d' \
                -e 's|^WantedBy=.*|WantedBy=default.target|' "$UNIT_DIR/beaut.service"
        fi
        $SYSTEMCTL daemon-reload
        case ",$ROLES_ARG," in
            *,hub,*|*,worker,*)
                $SYSTEMCTL enable beaut.service >/dev/null 2>&1 || true
                if $SYSTEMCTL restart beaut.service 2>/dev/null; then
                    info "beaut.service started"
                else
                    warn "beaut.service not running yet; check: $SYSTEMCTL status beaut"
                fi ;;
            *) info "client-only host: unit installed but not enabled" ;;
        esac
    fi
fi

info "done. try: beaut --help ; beaut config"
