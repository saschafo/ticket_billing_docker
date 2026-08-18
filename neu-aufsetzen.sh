#!/usr/bin/env bash
#
# Setzt die Site auf null und baut sie mit Demo-Daten und den gesicherten
# Postfächern wieder auf. Für Test- und Vorführzwecke.
#
# ACHTUNG: Löscht die Datenbank vollständig. Echte Tickets, Mailverläufe und
# Rechnungen sind danach weg -- und eingegangene Mails kommen nicht zurück,
# weil die Postfächer nur Ungelesenes liefern.
#
# Ablauf:
#   1. Postfach-Einstellungen sichern (wenn die Site noch läuft)
#   2. Volumes löschen, Site neu anlegen
#   3. ERPNext-Assistenten ohne Rückfragen abschliessen
#   4. Demo-Daten einspielen
#   5. Postfächer zurückspielen
#
#   ./neu-aufsetzen.sh              fragt nach
#   ./neu-aufsetzen.sh --ja         ohne Rückfrage (für Automatisierung)

set -euo pipefail
cd "$(dirname "$0")"

source .env
SITE="${SITE_NAME:-ticketbilling.localhost}"
SICHERUNG="mail-accounts.json"

FIRMA="${DEMO_COMPANY:-Musterfirma}"
KUERZEL="${DEMO_COMPANY_ABBR:-MF}"
LAND="${DEMO_COUNTRY:-Germany}"
WAEHRUNG="${DEMO_CURRENCY:-EUR}"
ZEITZONE="${DEMO_TIMEZONE:-Europe/Berlin}"
# Der Name muss exakt einem hinterlegten Kontenrahmen entsprechen. Passt er
# nicht, legt ERPNext die Firma an und stuerzt danach ab -- der Assistent
# faengt das ab und meldet trotzdem Erfolg. Gueltig fuer Deutschland:
# SKR04 mit Kontonummern, SKR03 mit Kontonummern, Standard,
# Standard with Numbers.
KONTENRAHMEN="${DEMO_COA:-SKR04 mit Kontonummern}"

# Ohne ausdrueckliche Daten legt der Assistent ein Geschaeftsjahr an, das
# seine eigene Pruefung nicht besteht ("End Date should be one year after
# Start Date"). Der Fehler wird protokolliert und uebersprungen -- man haette
# ein System ohne Geschaeftsjahr, in dem sich keine Rechnung schreiben laesst.
JAHR="${DEMO_FY_YEAR:-$(date +%Y)}"
FY_START="${DEMO_FY_START:-${JAHR}-01-01}"
FY_ENDE="${DEMO_FY_END:-${JAHR}-12-31}"
SPRACHE="${SITE_LANG:-de}"

if [[ "${1:-}" != "--ja" ]]; then
  echo "Dies löscht ALLE Daten der Site ${SITE}: Tickets, Mailverläufe, Rechnungen."
  echo "Eingegangene Mails kommen nicht zurück -- die Postfächer liefern nur Ungelesenes."
  read -r -p "Wirklich? [ja/NEIN] " antwort
  [[ "$antwort" == "ja" ]] || { echo "Abgebrochen."; exit 1; }
fi

# 1. Sichern, solange die Site noch steht. Schlägt das fehl, ist eine ältere
#    Sicherung besser als keine -- deshalb kein Abbruch.
echo "==> Postfächer sichern"
./mail-config.sh export "$SICHERUNG" 2>/dev/null || echo "    (keine laufende Site; nutze vorhandene ${SICHERUNG})"

# 2. Alles weg und neu
echo "==> Volumes löschen und Site neu anlegen"
docker compose down -v
./ticket.sh up

# 2b. Nach "down -v" sind die Container frisch aus dem Image. Alles, was
#     seit dem Bau lokal entstanden ist -- neue Module, neue Doctypes --
#     fehlt dort. dev-sync spielt es ein, migrate legt die Doctypes in der
#     Datenbank an. Ohne diesen Schritt bricht der Demo-Installer mit
#     "No module named 'ticket_billing.demo'" ab.
# Nur bei APP_SOURCE=local: Dort steckt der Code im Arbeitsbaum, nicht im
# Abbild. Bei APP_SOURCE=git bringt das Abbild die App bereits mit -- ein
# dev-sync wuerde sie mit dem lokalen Stand ueberschreiben und damit
# verschleiern, ob das Abbild allein traegt.
if [[ "${APP_SOURCE:-local}" == "local" ]]; then
  echo "==> Lokalen App-Stand einspielen"
  ./dev-sync.sh
else
  echo "==> App kommt aus dem Abbild (APP_SOURCE=${APP_SOURCE}), kein dev-sync"
fi
echo "==> Datenbank migrieren"
docker compose exec -T backend bench --site "$SITE" migrate

# 3. Assistent abschliessen. Ohne Firma verweigert der Demo-Installer.
echo "==> ERPNext-Assistenten abschliessen"
docker compose exec -T \
  -e TB_JAHR="${JAHR}" -e TB_FY_START="${FY_START}" -e TB_FY_ENDE="${FY_ENDE}" \
  -e TB_SPRACHE="${SPRACHE}" \
  -e TB_ARGS="{\"language\":\"${SPRACHE}\",\"country\":\"${LAND}\",\"currency\":\"${WAEHRUNG}\",\"timezone\":\"${ZEITZONE}\",\"company_name\":\"${FIRMA}\",\"company_abbr\":\"${KUERZEL}\",\"chart_of_accounts\":\"${KONTENRAHMEN}\",\"fy_start_date\":\"${FY_START}\",\"fy_end_date\":\"${FY_ENDE}\",\"full_name\":\"Administrator\"}" \
  -w /home/frappe/frappe-bench/sites backend ../env/bin/python - "$SITE" <<'PYTHON'
import json, os, sys
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete

frappe.init(site=sys.argv[1]); frappe.connect()
frappe.set_user("Administrator")
frappe.flags.in_setup_wizard = True

# Ein gescheiterter Lauf hinterlaesst die Site als "eingerichtet", obwohl
# keine Firma entstand -- danach steigt der Assistent sofort wieder aus und
# schweigt dazu. Der Schalter wird deshalb vorher zurueckgesetzt.
frappe.db.set_single_value("System Settings", "setup_complete", 0)
frappe.db.commit()

print("   ", setup_complete(json.loads(os.environ["TB_ARGS"])))
frappe.db.commit()
firma = frappe.db.get_value("Company", {}, "name")
if not firma:
    # setup_complete faengt Fehler ab und meldet trotzdem "ok". Ohne
    # diese Pruefung liefe das Skript weiter und schluege erst beim
    # Demo-Installer fehl -- weit weg von der Ursache.
    print("    FEHLER: Keine Firma angelegt. Siehe Error Log der Site.")
    sys.exit(1)
print("    Firma:", firma)

# Der Assistent ueberspringt fehlgeschlagene Saetze still. Was danach fehlt,
# wird hier nachgezogen, statt es erst beim ersten Rechnungslauf zu merken.
if not frappe.db.count("Fiscal Year"):
    frappe.get_doc({
        "doctype": "Fiscal Year",
        "year": os.environ["TB_JAHR"],
        "year_start_date": os.environ["TB_FY_START"],
        "year_end_date": os.environ["TB_FY_ENDE"],
    }).insert(ignore_permissions=True)
    print("    Geschaeftsjahr nachgetragen:", os.environ["TB_JAHR"])

# Der Assistent nimmt die Sprache nicht zuverlaessig an.
frappe.db.set_single_value("System Settings", "language", os.environ["TB_SPRACHE"])
frappe.db.set_default("lang", os.environ["TB_SPRACHE"])
frappe.db.commit()
print("    Sprache:", frappe.db.get_single_value("System Settings", "language"))
PYTHON

# 4. Demo
echo "==> Demo-Daten einspielen"
docker compose exec -T -w /home/frappe/frappe-bench/sites backend ../env/bin/python - "$SITE" <<'PYTHON'
import sys
import frappe
from ticket_billing.demo import install_demo_data

frappe.init(site=sys.argv[1]); frappe.connect()
frappe.set_user("Administrator")
print("   ", install_demo_data())
frappe.db.commit()
PYTHON

# 5. Postfächer
echo "==> Postfächer zurückspielen"
# Nicht nur auf Vorhandensein pruefen: Eine leere oder unvollstaendige Datei
# ist keine Sicherung. Sonst bricht der Lauf am Ende ab, obwohl alles davor
# geklappt hat.
if python3 -c "import json,sys; d=json.load(open('$SICHERUNG')); sys.exit(0 if d.get('accounts') else 1)" 2>/dev/null; then
  ./mail-config.sh import "$SICHERUNG"
else
  echo "    Keine brauchbare ${SICHERUNG} -- Postfächer bitte von Hand anlegen."
  echo "    Anleitung: README.md, Abschnitt 'E-Mail'."
fi

echo
echo "Fertig. http://${SITE}:8080/ticketbilling"
