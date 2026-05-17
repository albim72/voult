#!/usr/bin/env bash

# ============================================================
# VoltDB Day 1 Training Test Script
# Purpose:
#   Test środowiska VoltDB na potrzeby pierwszego dnia szkolenia:
#   Docker, Docker Compose, licencja, kontenery, porty,
#   VoltDB Management Center, Prometheus, Grafana oraz prosty test SQL.
#
# Usage:
#   chmod +x test_voltdb_day1.sh
#   ./test_voltdb_day1.sh
#
# Optional:
#   ./test_voltdb_day1.sh /path/to/dev-edition-app
#   LICENSE_FILE_PATH=/home/ubuntu/license.xml ./test_voltdb_day1.sh
# ============================================================

set -u

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "Komenda '$1' jest dostępna."
    else
        fail "Brakuje komendy '$1'."
    fi
}

check_url() {
    local name="$1"
    local url="$2"

    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 8 "$url" >/dev/null 2>&1; then
            pass "$name odpowiada pod adresem $url"
        else
            fail "$name nie odpowiada pod adresem $url"
        fi
    else
        warn "Nie można sprawdzić $url, bo brakuje curl."
    fi
}

wait_for_container() {
    local container_name="$1"
    local max_wait="${2:-90}"
    local elapsed=0

    info "Czekam na kontener: $container_name"

    while [ "$elapsed" -lt "$max_wait" ]; do
        local status
        local health

        status=$(sudo docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "not_found")
        health=$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "$container_name" 2>/dev/null || echo "not_found")

        if [ "$status" = "running" ]; then
            if [ "$health" = "healthy" ] || [ "$health" = "no_healthcheck" ]; then
                pass "Kontener $container_name działa. Status: $status, health: $health"
                return 0
            fi
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    fail "Kontener $container_name nie osiągnął poprawnego stanu w czasie ${max_wait}s."
    return 1
}

section "VoltDB Day 1 - test środowiska szkoleniowego"

DATE_NOW=$(date +"%Y-%m-%d %H:%M:%S")
info "Start testu: $DATE_NOW"

DEFAULT_PROJECT_DIR="$HOME/TollCollectDemo/dev-edition-app/target/dev-edition-app-1.0-SNAPSHOT/dev-edition-app"
PROJECT_DIR="${1:-$DEFAULT_PROJECT_DIR}"

section "1. Sprawdzenie katalogu projektu"

if [ -d "$PROJECT_DIR" ]; then
    pass "Katalog projektu istnieje: $PROJECT_DIR"
else
    fail "Nie znaleziono katalogu projektu: $PROJECT_DIR"
    echo
    echo "Podaj katalog ręcznie, np.:"
    echo "./test_voltdb_day1.sh ~/TollCollectDemo/dev-edition-app/target/dev-edition-app-1.0-SNAPSHOT/dev-edition-app"
    exit 1
fi

cd "$PROJECT_DIR" || exit 1

if [ -f "docker-compose.yml" ] || [ -f "compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    pass "Znaleziono plik Docker Compose."
else
    fail "Nie znaleziono docker-compose.yml / compose.yml / docker-compose.yaml w katalogu: $PROJECT_DIR"
    exit 1
fi

section "2. Sprawdzenie narzędzi systemowych"

check_command docker
check_command curl

if docker compose version >/dev/null 2>&1; then
    pass "Docker Compose działa jako: docker compose"
else
    fail "Docker Compose nie działa jako 'docker compose'."
fi

section "3. Sprawdzenie działania Dockera"

if sudo docker info >/dev/null 2>&1; then
    pass "Docker daemon działa poprawnie."
else
    fail "Docker daemon nie działa. Uruchom Docker albo zrestartuj maszynę."
    exit 1
fi

section "4. Sprawdzenie pliku licencji VoltDB"

DETECTED_LICENSE_FILE_PATH=""

if [ "${LICENSE_FILE_PATH:-}" != "" ] && [ -f "$LICENSE_FILE_PATH" ]; then
    DETECTED_LICENSE_FILE_PATH="$LICENSE_FILE_PATH"
fi

if [ "$DETECTED_LICENSE_FILE_PATH" = "" ]; then
    LICENSE_CANDIDATES=(
        "$HOME/license.xml"
        "/home/ubuntu/license.xml"
        "/home/xraytunnel/license.xml"
        "$PROJECT_DIR/license.xml"
    )

    for candidate in "${LICENSE_CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            DETECTED_LICENSE_FILE_PATH="$candidate"
            break
        fi
    done
fi

if [ -n "$DETECTED_LICENSE_FILE_PATH" ]; then
    pass "Znaleziono plik licencji: $DETECTED_LICENSE_FILE_PATH"
else
    warn "Nie znaleziono license.xml w typowych lokalizacjach."
    warn "Jeżeli VoltDB wymaga licencji, uruchom skrypt tak:"
    echo "LICENSE_FILE_PATH=/ścieżka/do/license.xml ./test_voltdb_day1.sh"
fi

section "5. Uruchomienie środowiska VoltDB"

if [ -n "$DETECTED_LICENSE_FILE_PATH" ]; then
    info "Uruchamiam Docker Compose z LICENSE_FILE_PATH=$DETECTED_LICENSE_FILE_PATH"
    sudo LICENSE_FILE_PATH="$DETECTED_LICENSE_FILE_PATH" docker compose up -d
else
    info "Uruchamiam Docker Compose bez jawnie ustawionej ścieżki licencji."
    sudo docker compose up -d
fi

if [ $? -eq 0 ]; then
    pass "docker compose up -d zakończone poprawnie."
else
    fail "docker compose up -d zakończyło się błędem."
    exit 1
fi

section "6. Status kontenerów"

sudo docker compose ps

echo
info "Lista działających kontenerów:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

section "7. Oczekiwanie na podstawowe kontenery"

for c in voltdb prometheus grafana; do
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
        wait_for_container "$c" 90
    else
        warn "Nie znaleziono kontenera o nazwie '$c'. Nazwy mogą być inne w tym compose."
    fi
done

section "8. Test usług HTTP"

check_url "VoltDB Management Center" "http://localhost:8080"
check_url "Grafana" "http://localhost:3000"
check_url "Prometheus" "http://localhost:9090"

section "9. Test podstawowych portów TCP"

if command -v nc >/dev/null 2>&1; then
    if nc -z localhost 8080 >/dev/null 2>&1; then
        pass "Port 8080 jest otwarty."
    else
        fail "Port 8080 nie jest otwarty."
    fi

    if nc -z localhost 21212 >/dev/null 2>&1; then
        pass "Port klienta VoltDB 21212 jest otwarty."
    else
        warn "Port 21212 nie odpowiada. Może nie być wystawiony na hosta."
    fi

    if nc -z localhost 3000 >/dev/null 2>&1; then
        pass "Port Grafany 3000 jest otwarty."
    else
        warn "Port Grafany 3000 nie odpowiada."
    fi

    if nc -z localhost 9090 >/dev/null 2>&1; then
        pass "Port Prometheusa 9090 jest otwarty."
    else
        warn "Port Prometheusa 9090 nie odpowiada."
    fi
else
    warn "Brakuje komendy nc. Pomijam test portów TCP."
    warn "Możesz zainstalować: sudo apt install netcat-openbsd"
fi

section "10. Test dostępu do kontenera VoltDB"

if sudo docker ps --format '{{.Names}}' | grep -q "^voltdb$"; then
    if sudo docker exec voltdb echo "VoltDB container access OK" >/dev/null 2>&1; then
        pass "Można wykonać komendę wewnątrz kontenera voltdb."
    else
        fail "Nie można wykonać komendy wewnątrz kontenera voltdb."
    fi
else
    warn "Kontener 'voltdb' nie został znaleziony po nazwie. Pomijam docker exec voltdb."
fi

section "11. Test SQL VoltDB"

SQL_TEST_DONE=0

if sudo docker ps --format '{{.Names}}' | grep -q "^voltdb$"; then
    info "Próbuję wykonać prosty test SQL przez sqlcmd."

    if sudo docker exec -i voltdb bash -lc "command -v sqlcmd" >/dev/null 2>&1; then
        sudo docker exec -i voltdb bash -lc "echo 'SELECT 1;' | sqlcmd" >/tmp/voltdb_sql_test.log 2>&1

        if [ $? -eq 0 ]; then
            pass "Test SQL SELECT 1 wykonany poprawnie."
            SQL_TEST_DONE=1
        else
            warn "sqlcmd istnieje, ale SELECT 1 nie przeszedł. Log:"
            cat /tmp/voltdb_sql_test.log
        fi

    elif sudo docker exec -i voltdb bash -lc "test -x /opt/voltdb/bin/sqlcmd" >/dev/null 2>&1; then
        sudo docker exec -i voltdb bash -lc "echo 'SELECT 1;' | /opt/voltdb/bin/sqlcmd" >/tmp/voltdb_sql_test.log 2>&1

        if [ $? -eq 0 ]; then
            pass "Test SQL SELECT 1 wykonany poprawnie przez /opt/voltdb/bin/sqlcmd."
            SQL_TEST_DONE=1
        else
            warn "Znaleziono /opt/voltdb/bin/sqlcmd, ale test SQL nie przeszedł. Log:"
            cat /tmp/voltdb_sql_test.log
        fi
    else
        warn "Nie znaleziono sqlcmd w kontenerze voltdb."
    fi
else
    warn "Brak kontenera voltdb. Pomijam test SQL."
fi

if [ "$SQL_TEST_DONE" -eq 0 ]; then
    warn "Test SQL nie został wykonany albo zakończył się ostrzeżeniem."
    warn "To nie musi oznaczać awarii. W niektórych obrazach sqlcmd nie jest dostępny w kontenerze."
fi

section "12. Mini-scenariusz dla uczestników Dnia 1"

cat <<'EOF'

Ćwiczenia dla uczestnika:

1. Otwórz VoltDB Management Center:
   http://localhost:8080

2. Otwórz Grafanę:
   http://localhost:3000

3. Otwórz Prometheusa:
   http://localhost:9090

4. Sprawdź status kontenerów:
   sudo docker compose ps

5. Sprawdź logi VoltDB:
   sudo docker compose logs voltdb --tail=50

6. Sprawdź logi Prometheusa:
   sudo docker compose logs prometheus --tail=50

7. Sprawdź logi Grafany:
   sudo docker compose logs grafana --tail=50

8. Zatrzymaj środowisko:
   sudo docker compose stop

9. Uruchom ponownie:
   sudo docker compose up -d

10. Sprawdź, czy po restarcie nadal działa:
    http://localhost:8080

EOF

section "13. Podsumowanie testu"

echo -e "${GREEN}PASS:${NC} $PASS_COUNT"
echo -e "${YELLOW}WARN:${NC} $WARN_COUNT"
echo -e "${RED}FAIL:${NC} $FAIL_COUNT"

echo

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}Środowisko wygląda dobrze na Dzień 1 szkolenia.${NC}"
    echo "Możesz przejść do części: architektura VoltDB, Docker Compose, monitoring, UI, pierwsza diagnostyka."
else
    echo -e "${RED}Wykryto błędy. Najpierw popraw środowisko, zanim dasz je uczestnikom.${NC}"
fi

echo
echo "Adresy do użycia:"
echo "VoltDB Management Center: http://localhost:8080"
echo "Grafana:                  http://localhost:3000"
echo "Prometheus:               http://localhost:9090"

echo
info "Koniec testu."
