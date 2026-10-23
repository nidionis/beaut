#!/usr/bin/env bash
# libvirt-vm.sh — laboratory VM harness for a real libvirt/QEMU data plane.
#
# It does NOT start a VM unless --run is given.  The default output is the
# domain XML, so the CPU pinning and qcow2 layout can be reviewed first.
#
#   ./libvirt-vm.sh --name lab1 --cpus 0,1 --memory 1024 \
#     --image /srv/images/debian-13-base.qcow2 --print-xml
#
#   ./libvirt-vm.sh ... --run
#   ./libvirt-vm.sh --name lab1 --destroy
#
# The base image is never modified.  Each VM gets a qcow2 overlay under
# lab/out/vm/<name>/.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
OUT_ROOT="${LAB_VM_OUT_DIR:-$HERE/out/vm}"
URI="${LIBVIRT_URI:-qemu:///session}"

NAME="lab-vm"
CPUS=""
MEMORY=1024          # MiB
DISK_GB=10
IMAGE=""
NETWORK="user"       # user | none | bridge:<name> | network:<name>
RUN=0
DESTROY=0
PRINT_XML=0
KEEP_DISK=0

usage() {
  cat <<EOF
usage: $(basename "$0") [options]

  --name NAME       libvirt domain name (default: $NAME)
  --cpus LIST       host CPUs for vCPU pinning, e.g. 0,1 or 0-3
                    (default: current affinity list)
  --memory MiB      guest memory (default: $MEMORY)
  --disk GiB        qcow2 overlay size (default: $DISK_GB)
  --image PATH      read-only qcow2/raw base image (required with --run)
  --network SPEC    user (default), none, bridge:<name>, network:<name>
  --uri URI         libvirt connection (default: $URI)
  --run             create the overlay, define, and start the domain
  --print-xml       print the generated domain XML (no changes)
  --destroy         destroy/undefine the domain and remove its overlay
  --keep-disk       with --destroy, keep the overlay directory
  -h, --help        show this help

Environment:
  LIBVIRT_URI       default libvirt connection
  LAB_VM_OUT_DIR    overlay/XML directory (default: $OUT_ROOT)

Examples:
  $(basename "$0") --name lab1 --cpus 0,1 --memory 1024 \\
    --image /srv/images/debian-13-base.qcow2 --print-xml

  $(basename "$0") --name lab1 --destroy
EOF
}

die()  { printf 'libvirt-vm: %s\n' "$*" >&2; exit 1; }
warn() { printf 'libvirt-vm: warning: %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

expand_cpus() {
  local spec="$1" part lo hi c
  local -a parts out=()
  local -A seen=()
  IFS=',' read -r -a parts <<<"$spec"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [ -n "$part" ] || continue
    if [[ "$part" == *-* ]]; then
      lo="${part%%-*}"
      hi="${part##*-}"
      [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || die "bad CPU range: $part"
      (( 10#$lo <= 10#$hi )) || die "bad CPU range: $part"
      for ((c = 10#$lo; c <= 10#$hi; c++)); do
        [[ -n "${seen[$c]:-}" ]] && continue
        seen[$c]=1
        out+=("$c")
      done
    else
      [[ "$part" =~ ^[0-9]+$ ]] || die "bad CPU: $part"
      c=$((10#$part))
      [[ -n "${seen[$c]:-}" ]] && continue
      seen[$c]=1
      out+=("$c")
    fi
  done
  [ "${#out[@]}" -gt 0 ] || die "no CPUs selected"
  printf '%s\n' "${out[@]}"
}

default_cpus() {
  local list=""
  if command -v taskset >/dev/null 2>&1; then
    list="$(taskset -pc $$ 2>/dev/null | sed -n 's/^.*affinity list: //p')"
  fi
  if [[ ! "$list" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
    list="0-$(( $(nproc 2>/dev/null || echo 1) - 1 ))"
  fi
  printf '%s' "$list"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)      NAME="${2:-}"; shift 2 ;;
      --cpus)      CPUS="${2:-}"; shift 2 ;;
      --memory)    MEMORY="${2:-}"; shift 2 ;;
      --disk)      DISK_GB="${2:-}"; shift 2 ;;
      --image)     IMAGE="${2:-}"; shift 2 ;;
      --network)   NETWORK="${2:-}"; shift 2 ;;
      --uri)       URI="${2:-}"; shift 2 ;;
      --run)       RUN=1; shift ;;
      --print-xml) PRINT_XML=1; shift ;;
      --destroy)   DESTROY=1; shift ;;
      --keep-disk) KEEP_DISK=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
}

parse_args "$@"

[ -n "$NAME" ] || die "name must not be empty"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid domain name: $NAME"
[[ "$MEMORY" =~ ^[1-9][0-9]*$ ]] || die "--memory must be a positive integer"
[[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "--disk must be a positive integer"
[ "$RUN" -eq 0 ] || [ "$DESTROY" -eq 0 ] || die "--run and --destroy are mutually exclusive"
[ "$RUN" -eq 0 ] || [ "$PRINT_XML" -eq 0 ] || die "--run and --print-xml are mutually exclusive"
[ "$DESTROY" -eq 0 ] || [ "$PRINT_XML" -eq 0 ] || die "--destroy and --print-xml are mutually exclusive"
[ "$RUN" -eq 1 ] || [ "$DESTROY" -eq 1 ] || [ "$PRINT_XML" -eq 1 ] || {
  usage >&2
  die "choose --print-xml, --run, or --destroy"
}

RUN_DIR="$OUT_ROOT/$NAME"
OVERLAY="$RUN_DIR/disk.qcow2"
XML_FILE="$RUN_DIR/domain.xml"

# ---------------------------------------------------------------------------
# destroy
# ---------------------------------------------------------------------------
if [ "$DESTROY" -eq 1 ]; then
  need_cmd virsh
  if virsh -c "$URI" dominfo "$NAME" >/dev/null 2>&1; then
    virsh -c "$URI" destroy "$NAME" >/dev/null 2>&1 || true
    if ! virsh -c "$URI" undefine "$NAME" --nvram >/dev/null 2>&1; then
      virsh -c "$URI" undefine "$NAME" >/dev/null 2>&1 || true
    fi
    printf 'removed domain %s\n' "$NAME"
  else
    printf 'domain %s is not defined on %s\n' "$NAME" "$URI"
  fi
  if [ "$KEEP_DISK" -eq 0 ]; then
    case "$RUN_DIR" in
      "$OUT_ROOT"/*) rm -rf -- "$RUN_DIR" ;;
      *) die "refusing to remove unsafe path: $RUN_DIR" ;;
    esac
    printf 'removed overlay directory %s\n' "$RUN_DIR"
  else
    printf 'kept overlay directory %s\n' "$RUN_DIR"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# validate resources
# ---------------------------------------------------------------------------
[ -n "$CPUS" ] || CPUS="$(default_cpus)"
mapfile -t CPU_LIST < <(expand_cpus "$CPUS")
VCPUS="${#CPU_LIST[@]}"
[ "$VCPUS" -gt 0 ] || die "no CPUs selected"
CPU_SET="$(IFS=,; printf '%s' "${CPU_LIST[*]}")"

case "$NETWORK" in
  user|none) ;;
  bridge:*)  [[ -n "${NETWORK#bridge:}" ]] || die "empty bridge name" ;;
  network:*) [[ -n "${NETWORK#network:}" ]] || die "empty network name" ;;
  *) die "--network must be user, none, bridge:<name>, or network:<name>" ;;
esac

if [ -n "$IMAGE" ]; then
  [ -f "$IMAGE" ] || die "base image not found: $IMAGE"
  IMAGE="$(readlink -f "$IMAGE")"
  need_cmd qemu-img
  BASE_FMT="$(LC_ALL=C qemu-img info "$IMAGE" | awk -F': ' '/file format:/{print $2; exit}')"
  [ -n "$BASE_FMT" ] || die "cannot determine format of base image: $IMAGE"
else
  BASE_FMT=""
  [ "$RUN" -eq 0 ] || die "--image is required with --run (use --print-xml to preview)"
fi

if [ "$RUN" -eq 1 ]; then
  [ -e "$RUN_DIR" ] && die "already exists: $RUN_DIR (use --destroy first)"
  need_cmd virsh
  need_cmd qemu-img
  need_cmd qemu-system-x86_64
  virsh -c "$URI" list --all >/dev/null 2>&1 \
    || die "cannot connect to libvirt at $URI (start libvirtd or use --uri)"
fi

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  DOMAIN_TYPE="kvm"
  CPU_MODE="host-passthrough"
else
  DOMAIN_TYPE="qemu"
  CPU_MODE="host-model"
  warn "/dev/kvm is not readable/writable; falling back to TCG (slow)"
fi

# ---------------------------------------------------------------------------
# render domain XML
# ---------------------------------------------------------------------------
render_xml() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<domain type='$DOMAIN_TYPE'>
  <name>$(xml_escape "$NAME")</name>
  <memory unit='MiB'>$MEMORY</memory>
  <currentMemory unit='MiB'>$MEMORY</currentMemory>
  <vcpu placement='static'>$VCPUS</vcpu>
  <cputune>
EOF
  for i in "${!CPU_LIST[@]}"; do
    printf "    <vcpupin vcpu='%s' cpuset='%s'/>\n" "$i" "${CPU_LIST[$i]}"
  done
  cat <<EOF
    <emulatorpin cpuset='$CPU_SET'/>
  </cputune>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='$CPU_MODE' check='none'/>
  <clock offset='utc'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$(xml_escape "$OVERLAY")'/>
      <target dev='vda' bus='virtio'/>
    </disk>
EOF
  case "$NETWORK" in
    user)
      cat <<'EOF'
    <interface type='user'>
      <model type='virtio'/>
    </interface>
EOF
      ;;
    none) ;;
    bridge:*)
      printf "    <interface type='bridge'>\n"
      printf "      <source bridge='%s'/>\n" "$(xml_escape "${NETWORK#bridge:}")"
      printf "      <model type='virtio'/>\n"
      printf "    </interface>\n"
      ;;
    network:*)
      printf "    <interface type='network'>\n"
      printf "      <source network='%s'/>\n" "$(xml_escape "${NETWORK#network:}")"
      printf "      <model type='virtio'/>\n"
      printf "    </interface>\n"
      ;;
  esac
  cat <<'EOF'
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
}

XML_CONTENT="$(render_xml)"

if [ "$RUN" -eq 0 ]; then
  printf '%s\n' "$XML_CONTENT"
  exit 0
fi

# ---------------------------------------------------------------------------
# create overlay + define + start
# ---------------------------------------------------------------------------
mkdir -p "$RUN_DIR"
if ! qemu-img create -f qcow2 -F "$BASE_FMT" -b "$IMAGE" "$OVERLAY" "${DISK_GB}G"; then
  rm -rf -- "$RUN_DIR"
  die "failed to create qcow2 overlay"
fi
printf '%s\n' "$XML_CONTENT" >"$XML_FILE"

if ! virsh -c "$URI" define "$XML_FILE"; then
  rm -rf -- "$RUN_DIR"
  die "libvirt refused the domain XML"
fi
if ! virsh -c "$URI" start "$NAME"; then
  warn "domain is defined but did not start; inspect with: virsh -c $URI dominfo $NAME"
  exit 1
fi

cat <<EOF

VM started.
  name:     $NAME
  uri:      $URI
  cpus:     $CPU_SET ($VCPUS vCPU)
  memory:   ${MEMORY} MiB
  overlay:  $OVERLAY
  xml:      $XML_FILE
  console:  virsh -c "$URI" console "$NAME"
  info:     virsh -c "$URI" vcpuinfo "$NAME"
  stop:     $(basename "$0") --name "$NAME" --destroy
EOF
