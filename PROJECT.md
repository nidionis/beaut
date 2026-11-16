# Project concept

## Summary

The fabric is a small, operator-owned arrangement of machines: one coordinating point, a shared content-addressed store, a public-name and path routing layer, and durable named sessions with inter-worker backups. It targets mixed, intermittently available machines on private links, with a human close enough to inspect, repair and decide.

## Problem

This project prefers a baseline: understandable, repairable by hand, forgiving of unreliable machines and honest about its limits.

## Principles

- **One owner per decision.** The hub coordinates; workers execute/store.
- **Configuration declares inventory.** The operator says what should exist; records say what happened; reports say what is happening now.
- **Content identifies content.** A package is named by its bytes, not by a human name.
- **Persistent** Every package records its known copies and whether it is below target.
- **Coarse persistence.** Sessions preserve stored state, not live memory or in-flight work.
- **Readable state.** Records are ordinary descriptions, not a hidden service.
- **Fail visibly.** Every operation succeeds or explains why it did not.
- **Small, reversible actions.** Additive changes are easy; destructive ones are explicit.

## Model

- **Hub:** accepts content, chooses placement, resolves routes, keeps session records and schedules backups.
- **Worker:** stores content, runs sessions, snapshots them and sends backups.
- **Backup destination:** a machine that stores archives/.
- **Package:** immutable bytes with a content-derived identity, a name, a kind and a copy target.
- **Chunk and manifest:** fixed-size content-identified pieces; the manifest gives reconstruction order.
- **Copy and store:** content held by a node; the store keeps one copy of each distinct chunk.
- **Route:** a rule mapping a public name and path to a worker endpoint.
- **Session:** a named, durable execution environment with one home worker.
- **Snapshot and backup:** saved writable state stored as a package; a self-contained archive with policy.

One coordinator, many workers inter-backingup. The coordinator  routes public names to worker endpoints. Workers store content, run named sessions and send backups outward. A session has one home, a blueprint, optional workspaces, an automatic route and an optional backup policy. Snapshots preserve stored state inside the fabric;. Configuration says what should exist; records say what happened; reports say what is happening now. Every important state is visible, every failure is recorded, every destructive action is explicit.

That is the project. The rest is implementation.


## How to

the project will need :
- ressources measurement :
    - command that catch the available ressources
    - awk script that format it well

- worker used through reverse ssh

- run docker through this ssh -R / snapshot / backup to a separated worker

- store snapshot/work/worker table in the hub

