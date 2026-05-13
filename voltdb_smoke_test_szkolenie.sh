#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VoltDB smoke test pod szkolenie na Ubuntu
# ============================================================
# Jak używać:
# 1. Uzupełnij sekcję KONFIGURACJA poniżej.
# 2. Uruchom:
#       chmod +x voltdb_smoke_test_szkolenie.sh
#       ./voltdb_smoke_test_szkolenie.sh
#
# Co robi skrypt:
# - sprawdza system i Javę
# - sprawdza narzędzia voltdb/sqlcmd/voltadmin
# - inicjalizuje DBROOT, jeśli trzeba
# - uruchamia VoltDB
# - wykonuje test SQL
# - sprawdza voltadmin status
# - robi shutdown --save
# - restartuje bazę
# - weryfikuje, że dane przetrwały restart
# - opcjonalnie uruchamia VMC, jeśli znajdzie binarkę
# ============================================================

# ---------------------------
# KONFIGURACJA
# ---------------------------
VOLT_HOME="${VOLT_HOME:-/opt/NAZWA_ROZPAKOWANEGO_KATALOGU_VOLTDB}"
LICENSE_FILE="${LICENSE_FILE:-$HOME/license.xml}"     # zostaw, jeśli masz Enterprise
DBROOT="${DBROOT:-$HOME/voltdb-lab/dbroot}"
WORKDIR="${WORKDIR:-$HOME/voltdb-lab}"
LOGDIR="${LOGDIR:-$WORKDIR/logs}"
CLIENT_PORT="${CLIENT_PORT:-21212}"
ADMIN_PORT="${ADMIN_PORT:-21211}"
HTTP_PORT="${HTTP_PORT:-8080}"
RUN_VMC="${RUN_VMC:-0}"                                # 1 = spróbuj uruchomić VMC
VMC_HOME="${VMC_HOME:-$HOME/vmc}"                      # katalog z rozpakowanym VMC, jeśli istnieje

# ---------------------------
# KOLORY I HELPERY
# ---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }

cleanup() {
  true
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Brakuje polecenia: $1"
    exit 1
  }
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local retries="${3:-60}"
  local sleep_sec="${4:-2}"

  for ((i=1; i<=retries; i++)); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_sec"
  done
  return 1
}

ensure_path() {
  if [[ -d "$VOLT_HOME/bin" ]]; then
    export PATH="$VOLT_HOME/bin:$PATH"
  fi
}

start_voltdb() {
  mkdir -p "$LOGDIR"
  local start_log="$LOGDIR/voltdb_start_$(date +%Y%m%d_%H%M%S).log"

  log "Uruchamiam VoltDB..."
  if [[ -f "$LICENSE_FILE" ]]; then
    nohup voltdb start --dir="$DBROOT" --license="$LICENSE_FILE" >"$start_log" 2>&1 &
  else
    nohup voltdb start --dir="$DBROOT" >"$start_log" 2>&1 &
  fi

  log "Czekam na port klienta ${CLIENT_PORT}..."
  if wait_for_port "127.0.0.1" "$CLIENT_PORT" 90 2; then
    log "VoltDB nasłuchuje na porcie ${CLIENT_PORT}"
  else
    err "VoltDB nie wystartował poprawnie. Log: $start_log"
    tail -n 80 "$start_log" || true
    exit 1
  fi
}

run_sql_file() {
  local file="$1"
  if ! sqlcmd < "$file"; then
    err "Błąd wykonywania SQL z pliku: $file"
    exit 1
  fi
}

try_start_vmc() {
  if [[ "$RUN_VMC" != "1" ]]; then
    warn "Pomijam VMC. Ustaw RUN_VMC=1, jeśli chcesz spróbować uruchomić GUI."
    return 0
  fi

  local vmc_bin=""
  if command -v vmc >/dev/null 2>&1; then
    vmc_bin="$(command -v vmc)"
  elif [[ -x "$VMC_HOME/bin/vmc" ]]; then
    vmc_bin="$VMC_HOME/bin/vmc"
  fi

  if [[ -z "$vmc_bin" ]]; then
    warn "Nie znalazłem binarki VMC. GUI nie zostanie uruchomione."
    return 0
  fi

  if (echo >"/dev/tcp/127.0.0.1/${HTTP_PORT}") >/dev/null 2>&1; then
    warn "Port ${HTTP_PORT} już jest zajęty. Pomijam start VMC."
    return 0
  fi

  mkdir -p "$LOGDIR"
  local vmc_log="$LOGDIR/vmc_$(date +%Y%m%d_%H%M%S).log"
  log "Uruchamiam VMC na porcie ${HTTP_PORT}..."
  nohup "$vmc_bin" --servers=127.0.0.1 --publicinterface=0.0.0.0:${HTTP_PORT} >"$vmc_log" 2>&1 &

  if wait_for_port "127.0.0.1" "$HTTP_PORT" 30 2; then
    log "VMC działa. Otwórz w przeglądarce: http://IP_SERWERA:${HTTP_PORT}/"
  else
    warn "VMC nie wstał w czasie oczekiwania. Sprawdź log: $vmc_log"
  fi
}

# ---------------------------
# START
# ---------------------------
log "=== TEST ŚRODOWISKA VOLTDB POD SZKOLENIE ==="

ensure_path

log "1. Informacje o systemie"
require_cmd lsb_release
lsb_release -a || true
uname -a || true
free -h || true
timedatectl || true

log "2. Weryfikacja Java i Python"
require_cmd java
require_cmd python3
java -version
python3 --version

log "3. Weryfikacja narzędzi VoltDB"
require_cmd voltdb
require_cmd sqlcmd
require_cmd voltadmin
which voltdb
which sqlcmd
which voltadmin

if [[ -f "$LICENSE_FILE" ]]; then
  log "4. Licencja znaleziona: $LICENSE_FILE"
else
  warn "Nie znaleziono pliku license.xml pod ścieżką: $LICENSE_FILE"
  warn "Jeśli używasz Enterprise Edition, popraw LICENSE_FILE przed uruchomieniem."
fi

log "5. Przygotowanie katalogów"
mkdir -p "$WORKDIR" "$LOGDIR"

if [[ ! -d "$DBROOT" ]]; then
  log "6. Inicjalizacja DBROOT"
  if [[ -f "$LICENSE_FILE" ]]; then
    voltdb init --dir="$DBROOT" --license="$LICENSE_FILE"
  else
    voltdb init --dir="$DBROOT"
  fi
else
  warn "DBROOT już istnieje: $DBROOT"
  warn "Pomijam init i używam istniejącego katalogu."
fi

log "7. Start VoltDB"
start_voltdb

log "8. Test administracyjny"
voltadmin status || {
  err "voltadmin status zwrócił błąd"
  exit 1
}

SQL1="$WORKDIR/test_cli.sql"
cat > "$SQL1" <<'SQL'
SHOW TABLES;

CREATE TABLE Runner (
    RunnerID INTEGER NOT NULL,
    Name VARCHAR(64),
    PRIMARY KEY (RunnerID)
);

INSERT INTO Runner VALUES (1, 'Marcin');
INSERT INTO Runner VALUES (2, 'Test');

SELECT * FROM Runner;
SELECT COUNT(*) AS ile_runnerow FROM Runner;

CREATE TABLE TrainingResult (
    RunnerID INTEGER NOT NULL,
    ResultID BIGINT NOT NULL,
    RaceName VARCHAR(64),
    DistanceKm INTEGER NOT NULL,
    DurationMin INTEGER NOT NULL,
    PRIMARY KEY (RunnerID, ResultID)
);

PARTITION TABLE TrainingResult ON COLUMN RunnerID;

INSERT INTO TrainingResult VALUES (1, 1001, 'Pieniny Ultra Trail', 33, 210);
INSERT INTO TrainingResult VALUES (1, 1002, 'Tatra Sky Marathon', 45, 600);
INSERT INTO TrainingResult VALUES (2, 1003, 'Test Run', 10, 60);

SELECT * FROM TrainingResult;
SELECT RunnerID, COUNT(*) FROM TrainingResult GROUP BY RunnerID;
SHOW TABLES;
SQL

log "9. Test SQL"
run_sql_file "$SQL1"

log "10. Opcjonalny start GUI VMC"
try_start_vmc

log "11. Snapshot i kontrolowany shutdown"
voltadmin shutdown --save || {
  err "Nie udało się wykonać voltadmin shutdown --save"
  exit 1
}

sleep 5

log "12. Restart VoltDB"
start_voltdb

SQL2="$WORKDIR/test_after_restart.sql"
cat > "$SQL2" <<'SQL'
SHOW TABLES;
SELECT COUNT(*) AS ile_runnerow FROM Runner;
SELECT COUNT(*) AS ile_wynikow FROM TrainingResult;
SELECT * FROM TrainingResult;
SQL

log "13. Weryfikacja po restarcie"
run_sql_file "$SQL2"

log "14. Status końcowy"
voltadmin status

cat <<EOF

============================================================
WYNIK: TEST ZAKOŃCZONY POPRAWNIE
============================================================

Sprawdzone:
- Java
- voltdb / sqlcmd / voltadmin
- init DBROOT
- start VoltDB
- test CREATE / INSERT / SELECT
- partycjonowanie
- voltadmin status
- snapshot + restart
- opcjonalnie VMC

Jeśli RUN_VMC=1 i VMC się uruchomił:
- otwórz w przeglądarce: http://IP_SERWERA:${HTTP_PORT}/

Logi:
- $LOGDIR

Jeśli chcesz uruchomić VMC:
- rozpakuj VMC
- ustaw VMC_HOME
- uruchom skrypt tak:
    RUN_VMC=1 VMC_HOME=\$HOME/vmc ./$(basename "$0")

============================================================
EOF
