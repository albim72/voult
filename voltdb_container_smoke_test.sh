#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VoltDB container smoke test
# ============================================================
# Obsługuje:
#   - Docker / Docker Compose
#   - Kubernetes
#
# Użycie:
#   chmod +x voltdb_container_smoke_test.sh
#   ./voltdb_container_smoke_test.sh
#
# Opcjonalne zmienne:
#   MODE=auto|docker|k8s          (domyślnie: auto)
#   CONTAINER_NAME=voltdb         (dla Docker)
#   POD_NAME=<pod>                (dla Kubernetes)
#   NAMESPACE=default             (dla Kubernetes)
#   VMC_URL=http://localhost:8080 (opcjonalny test GUI)
#   RUN_VMC_TEST=1                (0/1, domyślnie 1)
#   RUN_SNAPSHOT_TEST=0           (0/1, domyślnie 0)
#   SNAPSHOT_DIR=/tmp/voltdb/backup
# ============================================================

MODE="${MODE:-auto}"
CONTAINER_NAME="${CONTAINER_NAME:-voltdb}"
POD_NAME="${POD_NAME:-}"
NAMESPACE="${NAMESPACE:-default}"
RUN_VMC_TEST="${RUN_VMC_TEST:-1}"
VMC_URL="${VMC_URL:-http://localhost:8080}"
RUN_SNAPSHOT_TEST="${RUN_SNAPSHOT_TEST:-0}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/tmp/voltdb/backup}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Brakuje polecenia: $1"
    exit 1
  }
}

exec_in_target() {
  local cmd="$1"

  if [[ "$MODE" == "docker" ]]; then
    docker exec -i "$CONTAINER_NAME" sh -lc "$cmd"
  elif [[ "$MODE" == "k8s" ]]; then
    kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- sh -lc "$cmd"
  else
    err "Nieznany MODE=$MODE"
    exit 1
  fi
}

detect_mode() {
  if [[ "$MODE" == "docker" || "$MODE" == "k8s" ]]; then
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      MODE="docker"
      return 0
    fi
  fi

  if command -v kubectl >/dev/null 2>&1; then
    if [[ -n "$POD_NAME" ]]; then
      if kubectl get pod -n "$NAMESPACE" "$POD_NAME" >/dev/null 2>&1; then
        MODE="k8s"
        return 0
      fi
    else
      local first_pod
      first_pod="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/voltdb/ {print $1; exit}')"
      if [[ -n "${first_pod:-}" ]]; then
        POD_NAME="$first_pod"
        MODE="k8s"
        return 0
      fi
    fi
  fi

  err "Nie udało się wykryć środowiska. Ustaw ręcznie MODE=docker lub MODE=k8s."
  exit 1
}

check_target_ready() {
  if [[ "$MODE" == "docker" ]]; then
    require_cmd docker
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      err "Nie ma uruchomionego kontenera o nazwie: $CONTAINER_NAME"
      exit 1
    fi
    log "Tryb: Docker, kontener: $CONTAINER_NAME"
  else
    require_cmd kubectl
    if [[ -z "$POD_NAME" ]]; then
      err "Brak POD_NAME dla trybu Kubernetes"
      exit 1
    fi
    kubectl get pod -n "$NAMESPACE" "$POD_NAME" >/dev/null
    log "Tryb: Kubernetes, namespace: $NAMESPACE, pod: $POD_NAME"
  fi
}

TMP_SQL="$(mktemp)"
VERIFY_SQL="$(mktemp)"
cleanup() {
  rm -f "$TMP_SQL" "$VERIFY_SQL" 2>/dev/null || true
}
trap cleanup EXIT

TS="$(date +%Y%m%d_%H%M%S)"
SMOKE_TABLE="smoke_test_${TS}"
PART_TABLE="training_result_${TS}"

cat > "$TMP_SQL" <<SQL
CREATE TABLE ${SMOKE_TABLE} (
    id INTEGER NOT NULL,
    txt VARCHAR(32),
    PRIMARY KEY (id)
);

INSERT INTO ${SMOKE_TABLE} VALUES (1, 'ok');
INSERT INTO ${SMOKE_TABLE} VALUES (2, 'dziala');

SELECT * FROM ${SMOKE_TABLE};
SELECT COUNT(*) AS ile FROM ${SMOKE_TABLE};

CREATE TABLE ${PART_TABLE} (
    runner_id INTEGER NOT NULL,
    result_id BIGINT NOT NULL,
    race_name VARCHAR(64),
    duration_min INTEGER NOT NULL,
    PRIMARY KEY (runner_id, result_id)
);

PARTITION TABLE ${PART_TABLE} ON COLUMN runner_id;

INSERT INTO ${PART_TABLE} VALUES (1, 1001, 'Test Race', 60);
INSERT INTO ${PART_TABLE} VALUES (1, 1002, 'Test Race 2', 75);
INSERT INTO ${PART_TABLE} VALUES (2, 1003, 'Test Race 3', 90);

SELECT * FROM ${PART_TABLE};
SELECT runner_id, COUNT(*) FROM ${PART_TABLE} GROUP BY runner_id;
SQL

cat > "$VERIFY_SQL" <<SQL
SELECT COUNT(*) AS ile FROM ${SMOKE_TABLE};
SELECT COUNT(*) AS ile FROM ${PART_TABLE};
SHOW TABLES;
SQL

log "1. Wykrywanie środowiska"
detect_mode
check_target_ready

log "2. Test administracyjny: voltadmin status"
exec_in_target "voltadmin status"

log "3. Test SQL przez sqlcmd"
if [[ "$MODE" == "docker" ]]; then
  docker exec -i "$CONTAINER_NAME" sh -lc "sqlcmd" < "$TMP_SQL"
else
  kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- sh -lc "sqlcmd" < "$TMP_SQL"
fi

log "4. Weryfikacja tabel po utworzeniu"
if [[ "$MODE" == "docker" ]]; then
  docker exec -i "$CONTAINER_NAME" sh -lc "sqlcmd" < "$VERIFY_SQL"
else
  kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- sh -lc "sqlcmd" < "$VERIFY_SQL"
fi

if [[ "$RUN_VMC_TEST" == "1" ]]; then
  log "5. Test GUI VMC pod adresem: $VMC_URL"
  require_cmd curl
  if curl -fsS --max-time 10 "$VMC_URL" >/dev/null; then
    log "VMC odpowiada poprawnie pod: $VMC_URL"
  else
    warn "Nie udało się potwierdzić VMC pod: $VMC_URL"
    warn "Sprawdź ręcznie w przeglądarce."
  fi
else
  warn "Pomijam test VMC (RUN_VMC_TEST=0)."
fi

if [[ "$RUN_SNAPSHOT_TEST" == "1" ]]; then
  log "6. Snapshot test przez voltadmin save"
  exec_in_target "mkdir -p '$SNAPSHOT_DIR' && voltadmin save --blocking '$SNAPSHOT_DIR' Smoke_${TS}"
else
  warn "Pomijam snapshot test (RUN_SNAPSHOT_TEST=0)."
fi

cat <<EOF

============================================================
WYNIK: TEST ZAKOŃCZONY
============================================================

Tryb:               $MODE
Kontener/pod:       ${CONTAINER_NAME:-$POD_NAME}
Namespace:          $NAMESPACE
Tabela smoke:       $SMOKE_TABLE
Tabela partycjon.:  $PART_TABLE
VMC URL:            $VMC_URL

Sprawdzone:
- voltadmin status
- CREATE TABLE / INSERT / SELECT
- PARTITION TABLE
- odczyt tabel po utworzeniu
- opcjonalnie VMC
- opcjonalnie snapshot

Przykłady użycia:

Docker:
  MODE=docker CONTAINER_NAME=voltdb ./$(basename "$0")

Kubernetes:
  MODE=k8s NAMESPACE=default POD_NAME=<pod_voltdb> ./$(basename "$0")

Z VMC:
  RUN_VMC_TEST=1 VMC_URL=http://localhost:8080 ./$(basename "$0")

Ze snapshotem:
  RUN_SNAPSHOT_TEST=1 SNAPSHOT_DIR=/tmp/voltdb/backup ./$(basename "$0")

============================================================
EOF
