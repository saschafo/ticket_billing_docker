#!/usr/bin/env bash
# =============================================================================
# Entwicklungshilfe: den Stand aus apps-local/<app> in die laufenden Container
# spielen, ohne das Image neu zu bauen.
#
#   ./dev-sync.sh              # Dateien kopieren
#   ./dev-sync.sh --migrate    # zusätzlich 'bench migrate' fahren
#
# NUR für die Entwicklung. Der so eingespielte Stand lebt im Container und ist
# beim nächsten 'up --force-recreate' weg -- was ins Image soll, muss committet
# und mit ./build.sh gebaut werden.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "FEHLER: .env fehlt." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

APP_NAME=${APP_NAME:-ticket_billing}
SITE=${SITE_NAME:-ticketbilling.localhost}
SRC="apps-local/${APP_NAME}"
DEST="/home/frappe/frappe-bench/apps/${APP_NAME}"

if [[ ! -d "$SRC" ]]; then
  echo "FEHLER: ${SRC} fehlt." >&2
  exit 1
fi

# Alle Dienste, die App-Code oder App-Dateien brauchen:
#   - backend/scheduler/queue-*: führen die Hooks aus. Ein Ticket aus dem
#     Posteingang entsteht im Worker, nicht im Web-Prozess.
#   - frontend: nginx liefert /assets aus. sites/assets zeigt auf die
#     Bench-Assets, und die verlinken auf apps/<app>/<app>/public -- also auf
#     die Dateien IM nginx-Container. Ohne diesen Eintrag bliebe das gebaute
#     Vue-Frontend auf dem alten Stand, während die API schon den neuen hat.
SERVICES=(backend scheduler queue-short queue-long websocket frontend)

for svc in "${SERVICES[@]}"; do
  if [[ -z "$(docker compose ps -q "$svc" 2>/dev/null)" ]]; then
    echo "  ${svc}: läuft nicht, übersprungen"
    continue
  fi

  # COPYFILE_DISABLE: BSD-tar auf macOS legt sonst zu jeder Datei mit
  # erweiterten Attributen eine AppleDouble-Datei "._name" an. Frappe liest
  # jede Datei im fixtures-Ordner und scheitert an deren Binärinhalt.
  COPYFILE_DISABLE=1 tar -C "$SRC" \
      --exclude node_modules --exclude .git --exclude __pycache__ \
      -cf - . \
    | docker compose exec -T "$svc" tar -C "$DEST" -xf - 2>/dev/null

  docker compose exec -T "$svc" find "$DEST" -name '._*' -delete 2>/dev/null || true
  echo "  ${svc}: synchronisiert"
done

if [[ "${1:-}" == "--migrate" ]]; then
  echo
  echo "bench migrate ..."
  docker compose exec -T backend bench --site "$SITE" migrate
fi

# Der Web-Prozess behält importierte Module im Speicher. Neue Dateien liegen
# nach dem Kopieren zwar da, aber gunicorn arbeitet weiter mit dem alten
# Stand -- und zwar unauffällig: bench-Aufrufe starten einen eigenen Prozess
# und sehen den neuen Code, die API nicht. Deshalb hier immer neu starten.
# Nicht nur backend: Jeder Python-Prozess haelt Hooks und Module im Speicher.
# Eingehende Mails, geplante Aufgaben und Hintergrundjobs laufen in den
# Workern -- bleiben die stehen, laeuft dort weiter der alte Code, waehrend
# die API schon den neuen hat. Genau so lief ein neu eingehaengter Hook
# wochenlang nie: getestet wurde er ueber das Backend, ausgefuehrt haette
# ihn der Worker.
# Hooks liegen in Redis, nicht nur im Prozessspeicher. Ein Neustart allein
# holt eine geaenderte hooks.py deshalb NICHT ab: Der Dienst laeuft neu, liest
# die Hook-Liste aber weiter aus dem Zwischenspeicher. Genau daran lief ein
# neuer Hook ins Leere, obwohl er in der Datei stand.
echo
echo "Leere den Zwischenspeicher (sonst bleiben geaenderte Hooks unbeachtet) ..."
docker compose exec -T backend bench --site "$SITE" clear-cache >/dev/null

RESTART=(backend scheduler queue-short queue-long)

if [[ "${1:-}" != "--no-restart" ]]; then
  echo
  echo "Starte Python-Dienste neu (sonst bleibt der alte Stand im Speicher) ..."
  for svc in "${RESTART[@]}"; do
    [[ -n "$(docker compose ps -q "$svc" 2>/dev/null)" ]] || continue
    docker compose restart "$svc" >/dev/null && echo "  ${svc}: neu gestartet"
  done
fi

echo
echo "Fertig."
