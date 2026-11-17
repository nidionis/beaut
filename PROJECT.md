# Project concept

## Summary

The fabric is a small, operator-owned arrangement of machines: one coordinating
point, workers that run Docker workloads, readable records of what happened, and
durable snapshots backed up between workers. It targets mixed, intermittently
available machines on private links, with a human close enough to inspect,
repair and decide.

`FULLSCRIP.md` is the contract. The current code implements its minimal working
core; the rest is added in slices.

## Problem

This project prefers a baseline that is understandable, repairable by hand,
forgiving of unreliable machines and honest about its limits. A single hub gives
placement and routing one owner. Workers do the work and keep the data. Every
important state is a file an operator can read.

## Principles

- **One owner per decision.** The hub coordinates; workers execute and store.
- **Configuration declares inventory.** The operator says what should exist;
  records say what happened; reports say what is happening now.
- **Content identifies content.** A project archive is named by its bytes, not
  by a human name.
- **Coarse persistence.** Snapshots preserve stored state, not live memory or
  in-flight work.
- **Readable state.** Records are ordinary JSON and text, not a hidden service.
- **Fail visibly.** Every operation succeeds or explains why it did not.
- **Small, reversible actions.** Additive changes are easy; destructive ones are
  explicit.
- **Explicit addresses.** The runtime never assumes `localhost`, a loopback
  address or a default route.

## Model

Long-term terms:

- **Hub:** accepts projects, chooses placement, serves routes and keeps job,
  worker and snapshot records.
- **Worker:** runs Docker jobs, reports resources, snapshots its jobs and sends
  backups to another worker.
- **Job:** one container project placed on one primary worker with a sticky
  backup.
- **Project archive:** immutable bytes packed from a project folder, identified
  by a content hash.
- **Worker identity:** explicit address plus the first 16 hex characters of the
  SHA-256 hash of the worker's public key. No worker names.
- **Snapshot and backup:** saved writable state stored as an archive; the backup
  worker receives a copy.
- **Route:** a script under `site/` that answers a public path.

## Current implementation

The minimal core in this repository provides:

- one hub main listener and one work listener;
- workers that pull work with `curl ... | sh`;
- key-derived worker identity, heartbeats and resource reports;
- scheduling by `SCHEDULING_PRIO` with a lower-load tie-break;
- one-shot and long-running Dockerfile/Compose jobs;
- idempotent work scripts and per-job markers;
- snapshots sent to the assigned backup worker;
- failover when the primary stops heartbeating, including restoration from the
  latest snapshot the hub knows about;
- argument-free SSH deployment and a first-connection bootstrap;
- an end-to-end smoke test using real addresses and Docker.

## Deliberately deferred

- WireGuard address generation and key distribution.
- Git repositories for site, state and logs.
- Content-addressed package store and named sessions.
- `NEXT_CHIEF` and repeated failover.
- Docker volume and image capture in snapshots.
- Running deployed units as the separate `worker` account.
- Authentication, TLS and an external ingress.
- Remote deployment verification on a second machine.

## Next slices

1. WireGuard: generate hub/peer keys, write `node.env`, keep explicit addresses.
2. Git-backed site, state and log repositories with a commit delay.
3. Full snapshot/recovery: volumes, images, checksums and restore verification.
4. `NEXT_CHIEF=2` candidate lists and repeated failover.
5. Worker-account units and least-privilege deployment.
6. Remote deployment and first-connection tests.
