# Proposal: a real VM data plane with libvirt/QEMU

Status: **laboratory proposal**, not wired into the installed `beaut` runtime.

The current `beaut` executor runs a shell command:

```text
beaut run -> orchestrator -> watch -> bash -c "<command>"
```

This proposal replaces only that last step with a real virtual-machine backend:

```text
beaut run (VM spec) -> orchestrator -> watch -> libvirt -> QEMU/KVM -> guest
```

`beaut` stays the control plane: identity, approval levels, routing, placement,
signed records, and result reporting. **libvirt/QEMU is the data plane** that
owns vCPUs, guest memory, disks, and virtual devices.

This is a VM-per-node design. It is not a single-system-image machine and does
not pool RAM across hosts.

## 1. What is exploited

A worker advertises the resources it is allowed to lend. The scheduler then
places a VM on one worker; the VM gets real resources from that host.

| Resource | libvirt/QEMU mechanism | Notes |
|---|---|---|
| CPU | `vcpupin`, `emulatorpin`, host cpuset | One vCPU pinned to one selected host CPU, or a small set |
| Memory | `<memory>` / `<currentMemory>` | Guest RAM is host RAM; no remote-memory aggregation |
| Disk | qcow2 overlay backed by a base image | `virtio-blk`; later Ceph/NFS/NVMe-oF |
| Network | `virtio-net`, user/bridge/OVS | User mode for the lab; bridge/VXLAN for a cluster |
| USB | USB redirection / `usbredir` | Explicit allow-list only |
| PCI/GPU | VFIO passthrough, SR-IOV | Requires IOMMU and compatible second-hand hardware |
| Console | pty / serial console | `virsh console` and a serial log |

The important correction to the earlier "use spare cores" idea is that
`cores()` in `src/orch.c` currently only **advertises** a number. A VM backend
must actually pin vCPUs and reserve memory. A scheduler hint without cpuset and
memory enforcement is not resource isolation.

### Host prerequisites for second-hand hardware

Check these before promising VM capacity:

```sh
grep -Eoc '(vmx|svm)' /proc/cpuinfo   # hardware virtualization exposed
ls -l /dev/kvm                        # KVM device present
test -r /dev/kvm && test -w /dev/kvm && echo KVM usable
ls /sys/kernel/iommu_groups           # needed for PCI passthrough
free -m; df -h /var/lib/libvirt/images
```

Common failures on old machines:

- VT-x/AMD-V disabled in firmware, or no `vmx`/`svm` flag;
- no IOMMU, so GPU/PCI passthrough is unsafe or impossible;
- not enough RAM for both host and guest;
- SATA/USB disks too slow for several overlays;
- 1 GbE networking, which is fine for control traffic but not remote memory;
- missing `libvirt`/`qemu-img` packages or no permission to use `/dev/kvm`.

The lab script falls back to TCG if `/dev/kvm` is unavailable, but TCG is for
format testing, not for useful capacity.

## 2. Resource request

Add a VM task kind instead of treating the whole command as an opaque shell
string. A request could look like:

```text
kind=vm
image=debian-13-base
vcpus=2
cpus=0,1
memory_mib=2048
disk_gib=20
network=bridge:br0
domain=vm
timeout_s=3600
```

The signed `beaut` record still carries the requester identity. The worker:

1. verifies the record and level (level 2 to request a VM, level 1 to host);
2. checks that the requested CPU set, memory, and disk fit in its budget;
3. renders a **local** libvirt XML from a trusted template;
4. defines and starts the domain;
5. watches the domain state and posts `result`/`fail`.

Clients must not send raw libvirt XML. A raw XML API would allow host mounts,
PCI passthrough, or arbitrary host devices. The worker accepts a small,
validated resource request and chooses the XML itself.

## 3. Discovery and scheduling

Each worker can publish a resource record:

```text
vcpus_total=8
vcpus_free=5
memory_total_mib=16384
memory_free_mib=10240
disk_free_gib=200
gpu=none
kvm=1
iommu=1
domain=vm
```

Sources:

- `/sys/devices/system/cpu/online`, `/proc/meminfo`, `df`;
- `virsh capabilities`, `virsh nodeinfo`;
- `/dev/kvm` presence and permissions;
- `/sys/kernel/iommu_groups` for passthrough;
- a local reservation table for already running domains.

`pick` should filter by `kind`, domain, free vCPUs, free memory, and requested
features before ranking by load. `SCHEDULER_RESERVE_NODES` remains the
remote-peer reserve; the host itself is always eligible.

A simple allocation policy for the lab:

- never allocate the last host CPU;
- never overcommit vCPUs by default;
- reserve at least 512 MiB for the host;
- reject a VM if the qcow2 overlay cannot be allocated;
- use one VM per worker until the scheduler is resource-aware.

## 4. libvirt domain shape

The lab harness renders a domain similar to this:

```xml
<domain type='kvm'>
  <name>lab1</name>
  <memory unit='MiB'>1024</memory>
  <currentMemory unit='MiB'>1024</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='0'/>
    <vcpupin vcpu='1' cpuset='1'/>
    <emulatorpin cpuset='0,1'/>
  </cputune>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='/path/to/lab1/disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='user'>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='none'/>
    <memballoon model='virtio'/>
  </devices>
</domain>
```

`virsh vcpuinfo lab1` should show the chosen host CPU for each vCPU. That is the
proof that the VM is actually using the selected cores rather than only
reporting a count.

## 5. Storage

Use a **qcow2 overlay** over a shared read-only base image:

```sh
qemu-img create -f qcow2 -F qcow2 \
  -b /srv/beaut/images/debian-13-base.qcow2 \
  /srv/beaut/vms/lab1/disk.qcow2 20G
```

Benefits:

- each VM gets its own writable disk;
- the base image is not modified;
- snapshots and rollback are possible;
- the disk can later live on NFS/Ceph/NVMe-oF.

Limitations:

- a local overlay is tied to one host;
- live migration needs shared storage or block migration;
- qcow2 on a network filesystem requires care (locking, cache modes).

Do not use raw block devices from an untrusted request. The worker owns the
storage path and allocation.

## 6. Network

Lab default: QEMU user networking (`<interface type='user'>`). It needs no
bridge, but guests are behind NAT and not directly reachable.

Cluster options, in increasing complexity:

1. **Linux bridge** (`br0`) with one tap per VM;
2. **Open vSwitch** with VLANs/VXLAN;
3. **SR-IOV VF** passthrough for high throughput;
4. **WireGuard/VXLAN overlay** for nodes on different networks.

For a first implementation, keep user networking and expose a service with a
host port forward or an SSH proxy. Add bridge networking only after the VM
lifecycle and cleanup work reliably.

## 7. Peripherals

Peripherals are the hardest part to make portable across second-hand machines.

- **USB**: use `usbredir`/USB/IP with an explicit vendor/product allow-list.
- **PCI/GPU**: VFIO passthrough requires IOMMU; check `dmesg` and
  `/sys/kernel/iommu_groups`. A passed-through GPU belongs to one VM.
- **Disks**: prefer virtio-blk over raw SCSI passthrough.
- **Serial/console**: always provide a pty and a serial log.

Never let the client choose an arbitrary host PCI address or USB device. The
worker maps a logical device name (`gpu0`, `usb-serial0`) to a local, approved
device.

## 8. Security

The current `beaut` guarantees remain the outer boundary:

- every request is AEAD-encrypted and Ed25519-signed;
- identity is checked on every request, not only at connection time;
- level 2 is required to request a VM, level 1 to host one;
- the hub rate-limits records and drops invalid ones.

The VM boundary adds:

- run QEMU as a non-root user where possible;
- use sVirt/SELinux or AppArmor confinement;
- restrict the libvirt socket to the `libvirt`/`kvm` group;
- do not expose `qemu:///system` to clients;
- use read-only base images and per-VM overlays;
- set disk, memory, vCPU, and process quotas;
- validate names and paths; no client-supplied XML;
- keep `BEAUT_ALLOW_EXEC` separate from a future `BEAUT_ALLOW_VM`.

A compromised guest must not automatically become a host or cluster compromise.

## 9. Integration phases

### Phase 0 — this lab

- `lab/libvirt-vm.sh` renders XML, creates an overlay, and can define/start a VM.
- Manual verification with `virsh vcpuinfo`, `virsh dominfo`, `virsh console`.

### Phase 1 — one-node VM backend

- Add a `vm` task kind to the signed record.
- `watch` dispatches it to a helper (shell or C) instead of `bash -c`.
- The helper defines/starts the domain, waits, and posts a result.
- Gate it behind `BEAUT_ALLOW_VM=1` and level 2.

### Phase 2 — resource-aware scheduler

- Heartbeats include vCPU/memory/disk availability.
- `pick` filters by VM resource request and domain.
- A local reservation table prevents double allocation.

### Phase 3 — cluster features

- shared storage (NFS/Ceph);
- bridge/OVS networking;
- VM images and cloud-init;
- snapshots, stop/start, console access;
- optional live migration with shared storage and compatible CPU models.

### Phase 4 — devices

- USB allow-list;
- VFIO/GPU passthrough;
- SR-IOV;
- explicit IOMMU checks and failure reporting.

Do not start with live migration or device passthrough. Make define/start/stop/
destroy and cleanup reliable first.

## 10. What this is not

Even with libvirt/QEMU, this is still:

- **one VM per host at a time** (unless the scheduler packs several VMs);
- **not one machine with pooled RAM**;
- **not transparent remote memory**;
- **not remote PCIe without special hardware**;
- **not a replacement for KVM, QEMU, libvirt, Kubernetes, or KubeVirt**.

If the goal is a private VM cloud, k3s + KubeVirt or Proxmox already provides
the mature control plane. `beaut` can remain the secure, lightweight scheduler
and transport for a small second-hand cluster.

## 11. Acceptance tests for the lab

1. XML parses and defines with `virsh define`.
2. `virsh vcpuinfo` shows each vCPU on the requested host CPU.
3. `virsh dominfo` reports the requested memory.
4. Guest boots from the qcow2 overlay; base image remains unchanged.
5. Destroy/undefine removes the domain and leaves no QEMU process.
6. Two VMs with overlapping cpusets are refused by the scheduler.
7. A VM request below level 2 is refused; a forged record is dropped.
8. A client-supplied XML/device path is rejected.
9. Host reboot policy is explicit (`on_reboot`, `on_poweroff`, autostart).
10. A failed start posts `fail` with a useful libvirt error, not a silent hang.

## 12. Lab commands

```sh
# Preview the domain XML (no changes)
./lab/libvirt-vm.sh \
  --name lab1 --cpus 0,1 --memory 1024 \
  --image /srv/beaut/images/debian-13-base.qcow2 \
  --print-xml

# Define and start it (requires a bootable base image)
./lab/libvirt-vm.sh \
  --name lab1 --cpus 0,1 --memory 1024 \
  --image /srv/beaut/images/debian-13-base.qcow2 \
  --run

virsh -c qemu:///session vcpuinfo lab1
virsh -c qemu:///session dominfo lab1
virsh -c qemu:///session console lab1

# Stop, undefine, remove the overlay
./lab/libvirt-vm.sh --name lab1 --destroy
```

The script defaults to the unprivileged session URI
`qemu:///session`. For a system libvirt instance, set
`LIBVIRT_URI=qemu:///system` and run with the appropriate group permissions.
