# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mac-adapted deployment of [Project N.O.M.A.D.](https://github.com/Crosstalk-Solutions/project-nomad) — an offline-first knowledge/education server ("survival computer") that orchestrates Docker containers for AI chat (Ollama), offline Wikipedia (Kiwix), Khan Academy (Kolibri), offline maps, notes, and more.

This directory is NOT the upstream repo itself — it wraps it with Mac-specific compose files, NAS integration, and a sync script. The upstream source lives in `project-nomad/`.

## Architecture

- **`compose.yaml`** — Primary config, storage on NAS (`/Volumes/home/project-nomad/storage`)
- **`compose.local.yaml`** — Offline config, storage on local disk (`./nomad-data/storage`)
- **`nas-sync`** — Syncs storage, Docker images, and DB between NAS and laptop
- **`project-nomad/`** — Upstream repo clone (Crosstalk Solutions)
- **`nomad-data/`** — Local data (MySQL, Redis, and optionally storage when running offline)

## Commands

```bash
# Start (NAS-backed, primary):
docker compose up -d

# Start (local/offline):
docker compose -f compose.local.yaml up -d

# Stop:
docker compose down

# Backup to NAS (laptop → NAS):
./nas-sync push all                     # everything
./nas-sync push storage                 # just content files
./nas-sync push storage zim flatnotes   # selective categories
./nas-sync push images                  # save Docker images as tarballs
./nas-sync push db                      # dump database

# Restore from NAS (NAS → laptop):
./nas-sync pull all                     # full offline restore
./nas-sync pull storage zim maps        # selective restore
./nas-sync pull images                  # load Docker images from tarballs

# Switch DB service mount paths:
./nas-sync dbswitch local               # for offline/local mode
./nas-sync dbswitch nas                 # for NAS-backed mode

# Show content sizes:
./nas-sync sizes

# Rebuild ARM64 images from source (after upstream updates):
docker build --platform linux/arm64 -t project-nomad:local project-nomad/
docker build --platform linux/arm64 -t project-nomad-sidecar-updater:local project-nomad/install/sidecar-updater/
```

### Admin App Development (inside `project-nomad/admin/`)

```bash
npm run dev          # Dev server with HMR
npm run build        # Production build (node ace build)
npm run test         # Run tests
npm run lint         # ESLint
npm run typecheck    # TypeScript check
npm run format       # Prettier
```

## Key Decisions & Gotchas

- **Disk collector sidecar is omitted** — uses `lsblk` and `/proc/1/mounts` which don't exist on macOS. Disk info page shows placeholder data. This is cosmetic only.
- **GPU detection gracefully degrades** — reports "no GPU" since Docker Desktop can't pass through Apple Silicon GPUs. Ollama should run on the host instead (set remote URL to `http://host.docker.internal:11434` in the Nomad UI).
- **Images are built for ARM64** — the upstream publishes only `linux/amd64`. The local `:local` tagged images are native ARM64 builds. Don't `pull_policy: always` on the Crosstalk images or it'll overwrite with amd64.
- **Databases stay local** — MySQL and Redis are on `./nomad-data/`, not NAS. Databases over SMB are unusably slow.
- **NAS must be mounted** before starting with `compose.yaml`. The mount point is `/Volumes/home` (SMB share `NAS_Home`).
- **Benchmarks measure Docker VM** — sysbench runs inside Linux containers, results don't reflect native Mac performance.
- **Updater sidecar `sed -i`** — uses GNU sed inside Alpine, not BSD sed. No Mac compatibility issue since it runs in-container.

## Upstream App Architecture (project-nomad/admin/)

- **Backend:** AdonisJS 6 (Node.js 22, TypeScript), MySQL 8, Redis 7 (BullMQ queues)
- **Frontend:** React 19, Vite 6, Inertia.js, Tailwind CSS 4
- **Docker orchestration:** `dockerode` — admin container manages sub-service containers via Docker socket (DooD pattern)
- **Key services:** `docker_service.ts` (container lifecycle), `system_service.ts` (hardware/GPU detection), `benchmark_service.ts` (sysbench + AI scoring)
- **AI:** Ollama client + OpenAI-compatible API, Qdrant for RAG vector search, Tesseract OCR, pdf-parse
- **Sub-services installed dynamically:** Ollama, Kiwix, Kolibri, CyberChef, FlatNotes, ProtoMaps — each as separate Docker containers managed through the UI

## Development Principles

### TDD Cycle

Red → Green → Refactor. Write the simplest failing test, implement minimum code to pass, refactor only after tests pass. Run all tests after each change.

For defects: API-level failing test first, then smallest reproducing test, then fix.

### Tidy First

Separate structural changes (refactoring) from behavioral changes (features/fixes). Never mix in the same commit. Structural changes come first when both are needed.

### Commit Discipline

Only commit when all tests pass and warnings are resolved. Each commit is one logical unit. Label commits as structural or behavioral.

### Code Organization

- Organize by domain: all code for a single domain in one folder
- Colocate tests with the code they test

### Code Design

- Use dependency injection for testability
