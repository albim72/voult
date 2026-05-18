#!/usr/bin/env bash
set -u

echo "============================================================"
echo "VoltDB Day 1 - Docker smoke test środowiska szkoleniowego"
echo "============================================================"
echo "[INFO] Start testu: $(date)"
echo

PROJECT_DIR="$HOME/TollCollectDemo/dev-edition-app/target/dev-edition-app-1.0-SNAPSHOT/dev-edition-app"
LICENSE_FILE_PATH="${LICENSE_FILE_PATH:-$HOME/license.xml}"
VOLTDB_CONTAINER="${VOLTDB_CONTAINER:-voltdb}"
PROMETHEUS_CONTAINER="${PROMETHEUS_CONTAINER:-prometheus}"
GRAFANA_CONTAINER="${GRAFANA_CONTAINER:-grafana}"

PASS=0
FAIL=0
WARN=0

ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }
info() { echo "[INFO] $1"; }

echo "------------------------------------------------------------"
echo "1. Sprawdzenie katalogu projektu"
echo "------------------------------------------------------------"

if [ -d "$PROJECT_DIR" ]; then
  ok "Katalog projektu istnieje: $PROJECT_DIR"
else
  fail "Nie znaleziono katalogu projektu: $PROJECT_DIR"
  echo
  echo "Spróbuj znaleźć katalog ręcznie:"
  echo "find \$HOME -name docker-compose.yaml"
  echo
  exit 1
fi

cd "$PROJECT_DIR" || exit 1

if [ -f "docker-compose.yaml" ]; then
  ok "Znaleziono docker-compose.yaml"
else
  fail "Brak docker-compose.yaml w katalogu projektu"
  exit 1
fi

echo
echo "------------------------------------------------------------"
echo "2. Sprawdzenie pliku licencji"
echo "------------------------------------------------------------"

if [ -f "$LICENSE_FILE_PATH" ]; then
  ok "Plik licencji istnieje: $LICENSE_FILE_PATH"
else
  warn "Nie znaleziono pliku licencji: $LICENSE_FILE_PATH"
  warn "Jeżeli kontenery już działają, część testów może nadal przejść."
fi

export LICENSE_FILE_PATH

echo
echo "------------------------------------------------------------"
echo "3. Sprawdzenie Dockera i Docker Compose"
echo "------------------------------------------------------------"

if command -v docker >/dev/null 2>&1; then
  ok "Docker jest dostępny"
else
  fail "Brakuje komendy docker"
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  ok "Docker Compose jest dostępny"
else
  fail "Docker Compose nie działa"
  exit 1
fi

echo
echo "------------------------------------------------------------"
echo "4. Status kontenerów"
echo "------------------------------------------------------------"

docker compose ps || warn "docker compose ps zwrócił błąd"

echo
for c in "$VOLTDB_CONTAINER" "$PROMETHEUS_CONTAINER" "$GRAFANA_CONTAINER"; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    ok "Kontener działa: $c"
  else
    warn "Nie widzę działającego kontenera: $c"
  fi
done

echo
echo "------------------------------------------------------------"
echo "5. Test VoltDB wewnątrz kontenera"
echo "------------------------------------------------------------"

if docker exec "$VOLTDB_CONTAINER" bash -lc "command -v sqlcmd" >/dev/null 2>&1; then
  ok "sqlcmd jest dostępny w kontenerze $VOLTDB_CONTAINER"
else
  fail "Brakuje sqlcmd w kontenerze $VOLTDB_CONTAINER albo kontener nie działa"
fi

if docker exec "$VOLTDB_CONTAINER" bash -lc "command -v voltdb" >/dev/null 2>&1; then
  ok "voltdb jest dostępny w kontenerze $VOLTDB_CONTAINER"
else
  warn "Polecenie voltdb nie jest widoczne w kontenerze albo nie jest w PATH"
fi

echo
echo "------------------------------------------------------------"
echo "6. Lista tabel VoltDB"
echo "------------------------------------------------------------"

TABLE_OUTPUT="$(docker exec "$VOLTDB_CONTAINER" bash -lc "echo 'show tables;' | sqlcmd --servers=localhost" 2>&1 || true)"
echo "$TABLE_OUTPUT"

if echo "$TABLE_OUTPUT" | grep -qE "KNOWN_VEHICLES|SCAN_HISTORY|TOLL_LOCATIONS|VEHICLE_TYPES"; then
  ok "VoltDB odpowiada i zawiera tabele aplikacji"
else
  warn "Nie rozpoznano oczekiwanych tabel aplikacji w wyniku show tables"
fi

echo
echo "------------------------------------------------------------"
echo "7. Test podstawowego zapytania SQL"
echo "------------------------------------------------------------"

QUERY_OUTPUT="$(docker exec "$VOLTDB_CONTAINER" bash -lc "echo 'select count(*) from TOLL_LOCATIONS;' | sqlcmd --servers=localhost" 2>&1 || true)"
echo "$QUERY_OUTPUT"

if echo "$QUERY_OUTPUT" | grep -qiE "count|row|rows|[0-9]+"; then
  ok "Zapytanie SQL do TOLL_LOCATIONS zostało wykonane"
else
  warn "Nie udało się jednoznacznie potwierdzić wyniku zapytania SQL"
fi

echo
echo "------------------------------------------------------------"
echo "8. Test portów usług z poziomu hosta"
echo "------------------------------------------------------------"

check_url() {
  local name="$1"
  local url="$2"

  if command -v curl >/dev/null 2>&1; then
    if curl -sS --max-time 5 "$url" >/dev/null 2>&1; then
      ok "$name odpowiada pod adresem: $url"
    else
      warn "$name nie odpowiedział pod adresem: $url"
    fi
  else
    warn "Brak curl, pomijam test URL: $url"
  fi
}

check_url "Grafana" "http://localhost:3000"
check_url "Prometheus" "http://localhost:9090"

echo
echo "------------------------------------------------------------"
echo "9. Krótki raport dla prowadzącego"
echo "------------------------------------------------------------"

echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "[WYNIK] Środowisko nadaje się do ćwiczeń szkoleniowych."
  echo "        Ewentualne WARN oznaczają elementy do ręcznego sprawdzenia."
  exit 0
else
  echo
  echo "[WYNIK] Środowisko wymaga poprawy przed szkoleniem."
  exit 1
fi
