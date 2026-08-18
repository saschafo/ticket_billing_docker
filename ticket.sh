#!/usr/bin/env bash
# =============================================================================
# Bedienhilfe für den Ticket-Billing-Stack.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "FEHLER: .env fehlt. Anlegen mit:  cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

SITE=${SITE_NAME:-ticketbilling.localhost}
PORT=${HTTP_PUBLISH_PORT:-8080}

dc() { docker compose "$@"; }

usage() {
  cat <<EOF
Verwendung: ./ticket.sh <befehl> [args]

  up                Stack starten (Site wird beim ersten Start angelegt)
  down              Stack stoppen (Daten bleiben erhalten)
  restart           Stack neu starten
  status            Container-Status
  logs [service]    Logs folgen (ohne Angabe: alle)
  bench <args...>   bench im Backend ausführen, z. B. ./ticket.sh bench --site $SITE list-apps
  shell             Bash-Shell im Backend-Container
  migrate           bench migrate für $SITE
  update            Image neu bauen, Stack neu starten, migrieren
  backup            Backup inkl. Dateien nach ./backups/
  console           Frappe-Python-Konsole
  reset             ALLES löschen (Container + Volumes, inkl. Datenbank!)
EOF
}

cmd=${1:-}
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  up)
    # 'up -d' kehrt erst zurueck, wenn create-site fertig ist -- die
    # uebrigen Dienste warten per depends_on auf dessen Abschluss.
    echo "Starte (beim ersten Mal dauert die Site-Anlage ein paar Minuten) ..."
    dc up -d "$@"
    dc logs --tail=15 create-site || true
    echo
    echo "URL      : http://localhost:${PORT}   (auch: http://${SITE}:${PORT})"
    echo "Benutzer : Administrator"
    echo "Passwort : ${ADMIN_PASSWORD}"
    ;;
  down)     dc down "$@" ;;
  restart)  dc restart "$@" ;;
  status)   dc ps ;;
  logs)     dc logs -f --tail=100 "$@" ;;
  bench)    dc exec backend bench "$@" ;;
  shell)    dc exec backend bash ;;
  console)  dc exec backend bench --site "$SITE" console ;;
  migrate)  dc exec backend bench --site "$SITE" migrate ;;
  update)
    # Vor dem Update sichern: 'bench migrate' laeuft beim Hochfahren
    # automatisch, und ein mittendrin gescheiterter Patch hinterlaesst eine
    # halb migrierte Datenbank. Mit --no-backup abschaltbar.
    if [[ "${1:-}" == "--no-backup" ]]; then
      echo "HINWEIS: Update ohne vorherige Sicherung (--no-backup)." >&2
    elif [[ -z "$(dc ps -q backend 2>/dev/null)" ]]; then
      # Nicht stillschweigend überspringen -- genau dieser Fall tritt nach
      # einem Neustart des Rechners auf, und dann fehlt die Sicherung
      # ausgerechnet dann, wenn man sie am ehesten braucht.
      echo "HINWEIS: Stack läuft nicht, es wurde keine Sicherung angelegt." >&2
      echo "         Für eine Sicherung vorher: ./ticket.sh up && ./ticket.sh backup" >&2
      echo
    else
      echo "Sichere vor dem Update ..."
      "$0" backup
      echo
    fi
    ./build.sh --refresh
    dc up -d --force-recreate
    dc logs --tail=15 create-site || true
    echo
    echo "Aktualisiert. Bei Problemen zurueck auf den vorherigen Stand:"
    echo "  CUSTOM_TAG in .env auf den vorherigen Commit-Tag setzen, dann ./ticket.sh up"
    docker images "${CUSTOM_IMAGE:-ticket-billing/frappe}" \
      --format "  {{.Tag}}  ({{.CreatedSince}})" | head -6
    ;;
  backup)
    mkdir -p backups
    dc exec backend bench --site "$SITE" backup --with-files
    # Backups liegen im sites-Volume; von dort herauskopieren:
    cid=$(dc ps -q backend)
    docker cp "${cid}:/home/frappe/frappe-bench/sites/${SITE}/private/backups/." ./backups/
    echo "Backups liegen in ./backups/"
    ;;
  reset)
    read -r -p "Wirklich ALLE Daten (Datenbank, Site, Uploads) löschen? [ja/NEIN] " answer
    if [[ "$answer" == "ja" ]]; then
      dc down -v
      echo "Alles entfernt. Neu aufsetzen mit: ./ticket.sh up"
    else
      echo "Abgebrochen."
    fi
    ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unbekannter Befehl: $cmd" >&2
    echo
    usage
    exit 1
    ;;
esac
