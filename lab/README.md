# beaut laboratory

This directory contains experiments that are deliberately outside the
installed `beaut` runtime.

- [`VIRTUALIZATION.md`](VIRTUALIZATION.md) — proposal for a real VM data plane
  using libvirt/QEMU, with `beaut` kept as the control plane.
- [`libvirt-vm.sh`](libvirt-vm.sh) — small lab harness that generates a libvirt
  domain with pinned vCPUs and a qcow2 overlay. It is dry-run by default.

Requirements: `libvirt`/`virsh`, `qemu-system-x86_64`, `qemu-img`, and
`/dev/kvm` for hardware acceleration. The default connection is the
unprivileged `qemu:///session`; override it with `LIBVIRT_URI`.

Quick environment check:

```sh
virsh --version
qemu-system-x86_64 --version
test -r /dev/kvm && echo KVM available
```

Quick XML preview:

```sh
./libvirt-vm.sh --name lab1 --cpus 0,1 --memory 1024 \
  --image /path/to/base.qcow2 --print-xml
```

`--cpus` takes a host CPU list, not a count: `--cpus 0,1` creates two vCPUs and
pins them to host CPUs 0 and 1.

See `VIRTUALIZATION.md` for the design, limitations, and the integration path
into `beaut run`/`beaut watch`.

The harness was exercised with a throwaway qcow2 base image on
`qemu:///session`: `virsh vcpuinfo` showed vCPU 0 on CPU 0 and vCPU 1 on CPU 1,
and `--destroy` removed both the domain and its overlay.
