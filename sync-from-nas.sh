#!/bin/bash
set -euo pipefail

# Project N.O.M.A.D. — Sync everything from NAS to local laptop
# Copies storage files, Docker images, and database so Nomad can run
# fully offline without the NAS or internet.
#
# Usage:
#   ./sync-from-nas.sh          # full sync (storage + images + database)
#   ./sync-from-nas.sh storage  # sync only storage files
#   ./sync-from-nas.sh images   # sync only Docker images
#   ./sync-from-nas.sh db       # sync only database dump
#   ./sync-from-nas.sh restore  # recover everything from NAS
#   ./sync-from-nas.sh local    # switch DB paths to local mode
#   ./sync-from-nas.sh nas      # switch DB paths to NAS mode

NAS_STORAGE="/Volumes/home/project-nomad/storage"
NAS_IMAGES="/Volumes/home/project-nomad/docker-images"
LOCAL_STORAGE="./nomad-data/storage"
LOCAL_IMAGES="./nomad-data/docker-images"
COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"

NAS_STORAGE_PATH="/Volumes/home/project-nomad/storage"
LOCAL_STORAGE_PATH="/Users/zain/code/nomad/nomad-data/storage"
DB_USER="nomad_user"
DB_PASS="${DB_PASS}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[sync]${RESET} $*"; }
warn() { echo -e "${YELLOW}[sync]${RESET} $*"; }
err()  { echo -e "${RED}[sync]${RESET} $*" >&2; }

check_nas() {
    if [[ ! -d "$NAS_STORAGE" ]]; then
        err "NAS not mounted at $NAS_STORAGE"
        err "Mount it first (Finder > Go > Connect to Server) then retry."
        exit 1
    fi
    log "NAS is mounted."
}

check_mysql_running() {
    if ! docker ps --filter "name=nomad_mysql" --filter "status=running" --format '{{.Names}}' | grep -q nomad_mysql; then
        return 1
    fi
    return 0
}

wait_for_mysql() {
    log "  Waiting for MySQL to be healthy..."
    local retries=0
    while ! docker exec nomad_mysql mysqladmin ping -h localhost --silent 2>/dev/null; do
        sleep 2
        ((retries++))
        if [[ $retries -ge 30 ]]; then
            warn "  MySQL didn't become healthy in time."
            return 1
        fi
    done
    return 0
}

# ── Path switching ────────────────────────────────────────────────────
# Updates the container_config bind mount paths stored in the services table
# so sub-services (Kiwix, Kolibri, etc.) mount from the correct location.

switch_db_paths() {
    local from="$1"
    local to="$2"
    local label="$3"

    if ! check_mysql_running; then
        warn "MySQL container is not running. Cannot switch paths."
        warn "Start Nomad first, then retry."
        return 1
    fi

    # Check if any rows actually need updating
    local count
    count=$(docker exec nomad_mysql mysql -u "$DB_USER" -p"$DB_PASS" nomad -sN \
        -e "SELECT COUNT(*) FROM services WHERE container_config LIKE '%${from}%'" 2>/dev/null)

    if [[ "$count" -eq 0 ]]; then
        log "DB paths already set for ${label} — nothing to update."
        return 0
    fi

    docker exec nomad_mysql mysql -u "$DB_USER" -p"$DB_PASS" nomad \
        -e "UPDATE services SET container_config = REPLACE(container_config, '${from}', '${to}') WHERE container_config LIKE '%${from}%';" 2>/dev/null

    log "Updated $count service(s) to use ${label} storage paths."
}

switch_to_local() {
    log "Switching DB paths to local mode..."
    switch_db_paths "$NAS_STORAGE_PATH" "$LOCAL_STORAGE_PATH" "local"
}

switch_to_nas() {
    log "Switching DB paths to NAS mode..."
    switch_db_paths "$LOCAL_STORAGE_PATH" "$NAS_STORAGE_PATH" "NAS"
}

# ── Storage sync ──────────────────────────────────────────────────────
# Content categories that can be selectively synced.
# Each maps to a subdirectory inside storage/.
CONTENT_CATEGORIES=(
    "zim"          # Wikipedia, StackExchange, medical refs, prepper content (large)
    "maps"         # Offline map tiles (large)
    "kolibri"      # Khan Academy / Kolibri channels (large)
    "ollama"       # Ollama model weights (very large)
    "qdrant"       # Vector DB data for RAG
    "flatnotes"    # Notes
    "kb_uploads"   # Knowledge base uploads
)

show_storage_sizes() {
    log "Content on NAS:"
    for cat in "${CONTENT_CATEGORIES[@]}"; do
        local path="$NAS_STORAGE/$cat"
        if [[ -d "$path" ]]; then
            local size
            size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            printf "  %-14s %s\n" "$cat" "$size"
        fi
    done
    echo ""
    if [[ -d "$LOCAL_STORAGE" ]]; then
        log "Content on local:"
        for cat in "${CONTENT_CATEGORIES[@]}"; do
            local path="$LOCAL_STORAGE/$cat"
            if [[ -d "$path" ]]; then
                local size
                size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
                printf "  %-14s %s\n" "$cat" "$size"
            fi
        done
    fi
}

sync_storage() {
    local categories=("$@")

    # If no categories specified, sync everything
    if [[ ${#categories[@]} -eq 0 ]]; then
        categories=("${CONTENT_CATEGORIES[@]}")
        # Also sync top-level files (nomad-disk-info.json, ollama-models-cache.json, etc.)
        log "Syncing all storage files from NAS to local..."
        mkdir -p "$LOCAL_STORAGE"
        # Sync top-level files only (not directories — those are handled per-category)
        rsync -ah --progress \
            --exclude='logs/' \
            --exclude='db-backups/' \
            --include='*' --exclude='*/' \
            "$NAS_STORAGE/" "$LOCAL_STORAGE/" 2>/dev/null || true
    else
        log "Syncing selected categories: ${categories[*]}"
    fi

    mkdir -p "$LOCAL_STORAGE"
    for cat in "${categories[@]}"; do
        local src="$NAS_STORAGE/$cat"
        local dst="$LOCAL_STORAGE/$cat"
        if [[ -d "$src" ]]; then
            log "  Syncing $cat..."
            mkdir -p "$dst"
            rsync -ah --progress --delete "$src/" "$dst/"
        else
            warn "  $cat — not present on NAS, skipping."
        fi
    done

    log "Storage sync complete."
    du -sh "$LOCAL_STORAGE" | awk '{print "  Local storage size: "$1}'
}

# ── Docker image export/import ────────────────────────────────────────
# Saves all nomad-related images as tar files on NAS, then loads them locally.
# This means you can restore Docker images from NAS without internet.

NOMAD_IMAGES=(
    "project-nomad:local"
    "project-nomad-sidecar-updater:local"
    "mysql:8.0"
    "redis:7-alpine"
    "amir20/dozzle:v10.0"
)

save_images_to_nas() {
    log "Saving Docker images to NAS for offline recovery..."
    mkdir -p "$NAS_IMAGES"

    for img in "${NOMAD_IMAGES[@]}"; do
        local safe_name="${img//[:\/]/_}"
        local tar_path="$NAS_IMAGES/${safe_name}.tar"

        if ! docker image inspect "$img" &>/dev/null; then
            warn "Image $img not found locally, skipping."
            continue
        fi

        log "  Saving $img..."
        docker save "$img" -o "$tar_path"
    done

    # Also save any running nomad_ containers' images (catches sub-services
    # like ollama, kiwix, kolibri that Nomad installs dynamically)
    local extra_images
    extra_images=$(docker ps --filter "name=nomad_" --format '{{.Image}}' | sort -u)
    for img in $extra_images; do
        # Skip images we already saved
        local already_saved=false
        for known in "${NOMAD_IMAGES[@]}"; do
            [[ "$img" == "$known" ]] && already_saved=true
        done
        $already_saved && continue

        local safe_name="${img//[:\/]/_}"
        local tar_path="$NAS_IMAGES/${safe_name}.tar"
        log "  Saving sub-service image $img..."
        docker save "$img" -o "$tar_path" || warn "  Failed to save $img, continuing."
    done

    log "Docker images saved to NAS."
    du -sh "$NAS_IMAGES" | awk '{print "  Image archive size: "$1}'
}

load_images_from_nas() {
    log "Loading Docker images from NAS..."

    if [[ ! -d "$NAS_IMAGES" ]]; then
        warn "No saved images found at $NAS_IMAGES."
        warn "Run './sync-from-nas.sh images' while online to save them first."
        return 1
    fi

    local count=0
    for tar_file in "$NAS_IMAGES"/*.tar; do
        [[ -f "$tar_file" ]] || continue
        log "  Loading $(basename "$tar_file")..."
        docker load -i "$tar_file"
        ((count++))
    done

    log "Loaded $count Docker images."
}

sync_images() {
    # Save current images to NAS, then verify they load
    save_images_to_nas
    log "Docker images archived to NAS for offline recovery."
}

# ── Database dump ─────────────────────────────────────────────────────
sync_db() {
    local dump_dir="$NAS_STORAGE/db-backups"
    local local_dump_dir="$LOCAL_STORAGE/db-backups"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    if ! check_mysql_running; then
        warn "MySQL container is not running. Skipping database dump."
        warn "Start Nomad first, then run: ./sync-from-nas.sh db"
        return 1
    fi

    log "Dumping database..."
    mkdir -p "$dump_dir" "$local_dump_dir"

    docker exec nomad_mysql mysqldump \
        -u "$DB_USER" \
        -p"$DB_PASS" \
        --single-transaction \
        nomad > "$dump_dir/nomad-${timestamp}.sql"

    # Keep latest dump as a well-known name for easy restore
    cp "$dump_dir/nomad-${timestamp}.sql" "$dump_dir/nomad-latest.sql"
    cp "$dump_dir/nomad-latest.sql" "$local_dump_dir/nomad-latest.sql"

    # Keep only the 5 most recent dumps on NAS
    ls -t "$dump_dir"/nomad-2*.sql 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

    log "Database dumped to NAS and local."
}

# ── Restore (for total recovery) ──────────────────────────────────────
restore_from_nas() {
    log "${BOLD}Full restore from NAS — recovering everything for offline use.${RESET}"
    echo ""

    check_nas
    sync_storage "$@"
    echo ""
    load_images_from_nas
    echo ""

    # Restore database if a dump exists
    local dump_file="$NAS_STORAGE/db-backups/nomad-latest.sql"
    local local_dump="$LOCAL_STORAGE/db-backups/nomad-latest.sql"
    local restore_file=""

    if [[ -f "$local_dump" ]]; then
        restore_file="$local_dump"
    elif [[ -f "$dump_file" ]]; then
        restore_file="$dump_file"
    fi

    if [[ -n "$restore_file" ]]; then
        log "Restoring database from backup..."
        cd "$COMPOSE_DIR"
        docker compose -f compose.local.yaml up -d mysql
        wait_for_mysql || true
        docker exec -i nomad_mysql mysql \
            -u "$DB_USER" \
            -p"$DB_PASS" \
            nomad < "$restore_file"
        log "Database restored."

        # Switch paths to local since we're restoring for offline use
        switch_to_local
        docker compose -f compose.local.yaml down
    else
        warn "No database backup found. The app will run migrations to create a fresh DB."
    fi

    echo ""
    log "${BOLD}Restore complete.${RESET} Start Nomad with:"
    echo "  docker compose -f compose.local.yaml up -d"
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
    cd "$COMPOSE_DIR"
    local mode="${1:-full}"

    case "$mode" in
        storage)
            check_nas
            shift
            sync_storage "$@"
            ;;
        sizes)
            check_nas
            show_storage_sizes
            ;;
        images)
            check_nas
            sync_images
            ;;
        db)
            check_nas
            sync_db
            ;;
        full)
            check_nas
            shift
            echo ""
            sync_storage "$@"
            echo ""
            sync_images
            echo ""
            sync_db
            echo ""
            log "${BOLD}Full sync complete.${RESET}"
            log "To run offline: docker compose -f compose.local.yaml up -d"
            ;;
        restore)
            shift
            restore_from_nas "$@"
            ;;
        local)
            switch_to_local
            ;;
        nas)
            switch_to_nas
            ;;
        *)
            echo "Usage: $0 <command> [categories...]"
            echo ""
            echo "Commands:"
            echo "  full     — sync storage + images + DB (default)"
            echo "  storage  — sync content files from NAS"
            echo "  sizes    — show content sizes on NAS and local"
            echo "  images   — save Docker images to NAS for offline recovery"
            echo "  db       — dump MySQL database to NAS and local"
            echo "  restore  — recover everything from NAS (images + storage + DB)"
            echo "  local    — switch DB service paths to local storage"
            echo "  nas      — switch DB service paths to NAS storage"
            echo ""
            echo "Selective sync — pick which content to copy locally:"
            echo "  $0 storage zim flatnotes     # only ZIM files and notes"
            echo "  $0 full zim kb_uploads       # full sync but only these categories"
            echo "  $0 restore zim maps          # restore with only ZIM + maps"
            echo ""
            echo "Categories: ${CONTENT_CATEGORIES[*]}"
            exit 1
            ;;
    esac
}

main "$@"
