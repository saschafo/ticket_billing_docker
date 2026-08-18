#!/usr/bin/env bash
#
# Sichert die Postfach-Einstellungen und spielt sie zurück.
#
# Hintergrund: Die E-Mail-Konten werden von Hand angelegt und gehören nicht
# zu den Demo-Daten -- ein Entfernen der Demo fasst sie nicht an. Verloren
# gehen sie trotzdem leicht: beim Neuaufsetzen der Site, beim Zurücksetzen
# der Datenbank oder wenn der Container neu gebaut wird.
#
# Die Datei enthält im Regelfall die Postfach-Kennwörter. Sie wird deshalb
# mit 600 angelegt und ist über .gitignore vom Repo ausgeschlossen.
#
#   ./mail-config.sh export [datei]     Standard: mail-accounts.json
#   ./mail-config.sh export --ohne-passwort [datei]
#   ./mail-config.sh import [datei]

set -euo pipefail
cd "$(dirname "$0")"

# Eine von aussen gesetzte SITE_NAME hat Vorrang. Ohne das Merken vorab
# ueberschriebe .env sie wieder -- der Aufruf zeigte dann auf die falsche
# Site, und zwar unbemerkt.
SITE_VORGABE="${SITE_NAME:-}"
[[ -f .env ]] && source .env
SITE="${SITE_VORGABE:-${SITE_NAME:-ticketbilling.localhost}}"

BEFEHL="${1:-}"
shift || true

MIT_PASSWORT=1
if [[ "${1:-}" == "--ohne-passwort" ]]; then
  MIT_PASSWORT=0
  shift
fi
DATEI="${1:-mail-accounts.json}"

case "$BEFEHL" in
  export)
    TMP="${DATEI}.neu"
    ( docker compose exec -T -e MIT_PASSWORT="$MIT_PASSWORT" \
      -w /home/frappe/frappe-bench/sites backend ../env/bin/python - "$SITE" <<'PY' > "$TMP"
import json, os, sys
import frappe

frappe.init(site=sys.argv[1]); frappe.connect()

# Nur Einstellungen, keine Laufzeitspuren: uidnext/uidvalidity beschreiben
# den Stand des letzten Abrufs. Zurückgespielt würden sie das neue Postfach
# an eine Stelle setzen, die dort nichts bedeutet -- im schlimmsten Fall
# werden vorhandene Mails übersprungen.
LAUFZEIT = {"uidnext", "uidvalidity", "no_failed", "no_smtp_tab"}
UEBERSPRINGEN = {
    "password", "doctype", "owner", "modified_by", "creation", "modified",
    "idx", "docstatus", "_user_tags", "_comments", "_assign", "_liked_by",
    "imap_folder",
} | LAUFZEIT

mit_passwort = os.environ.get("MIT_PASSWORT") == "1"

# Die E-Mail-Domain gehoert dazu: Das Konto verweist darauf, und auf einer
# frischen Site existiert sie nicht. Ohne sie scheitert das Zurueckspielen
# mit "Could not find Domain".
domains = []
for name in frappe.get_all("Email Domain", pluck="name"):
    doc = frappe.get_doc("Email Domain", name).as_dict()
    domains.append({
        k: v for k, v in doc.items()
        if k not in UEBERSPRINGEN and k != "name" and v not in (None, "", [])
    } | {"name": name})

konten = []

for name in frappe.get_all("Email Account", pluck="name"):
    doc = frappe.get_doc("Email Account", name)
    eintrag = {
        k: v for k, v in doc.as_dict().items()
        if k not in UEBERSPRINGEN and v not in (None, "", [])
    }
    eintrag["imap_folder"] = [
        {k: v for k, v in f.items()
         if k in ("folder_name", "append_to")}
        for f in frappe.get_all(
            "IMAP Folder", filters={"parent": name},
            fields=["folder_name", "append_to"], order_by="idx",
        )
    ]
    if mit_passwort:
        try:
            eintrag["password"] = doc.get_password("password")
        except Exception:
            eintrag["password"] = None
    konten.append(eintrag)

print(json.dumps({"site": sys.argv[1], "domains": domains, "accounts": konten},
                 indent=2, ensure_ascii=False))
PY
    ) || true

    # Erst in eine Nebendatei, pruefen, dann erst ersetzen. Die Umleitung
    # legt die Zieldatei sonst auch dann an, wenn der Export scheitert --
    # eine vorhandene, gute Sicherung waere damit durch eine leere ersetzt.
    # Und zwar genau dann, wenn die Site nicht mehr laeuft und man keine
    # neue erzeugen kann.
    # Geprueft wird, ob gueltiges JSON mit der erwarteten Struktur entstand --
    # nicht, ob Konten drin sind. Eine Anlage ohne Postfaecher ist ein
    # gueltiger Zustand, und "null Konten" ist eine korrekte Sicherung davon.
    if ! python3 -c "import json,sys; d=json.load(open('$TMP')); sys.exit(0 if isinstance(d.get('accounts'), list) else 1)" 2>/dev/null; then
      rm -f "$TMP"
      echo "FEHLER: Export fehlgeschlagen (laeuft die Site?). ${DATEI} bleibt unveraendert." >&2
      exit 1
    fi
    mv "$TMP" "$DATEI"
    chmod 600 "$DATEI"
    anzahl=$(python3 -c "import json;print(len(json.load(open('$DATEI'))['accounts']))")
    echo "Gesichert: ${anzahl} Postfach/Postfächer -> ${DATEI} (Rechte 600)" >&2
    [[ "$MIT_PASSWORT" == "1" ]] && echo "Die Datei enthält Kennwörter im Klartext." >&2
    ;;

  import)
    [[ -f "$DATEI" ]] || { echo "FEHLER: ${DATEI} fehlt." >&2; exit 1; }
    # Die Daten kommen als Umgebungsvariable, nicht ueber stdin: Dort liegt
    # bereits das Skript. Beides umzuleiten heisst, dass die letzte Umleitung
    # gewinnt -- Python bekaeme die JSON-Datei als Programm. Weil ein
    # JSON-Objekt zufaellig auch ein gueltiger Python-Ausdruck ist, laeuft
    # das fehlerfrei durch und tut nichts: Exitcode 0, keine Meldung.
    docker compose exec -T -e TB_DATEN="$(cat "$DATEI")" \
      -w /home/frappe/frappe-bench/sites backend ../env/bin/python - "$SITE" <<'ENDE'
import json, os, sys
import frappe

daten = json.loads(os.environ["TB_DATEN"])
frappe.init(site=sys.argv[1]); frappe.connect()
frappe.set_user("Administrator")

# Zuerst die Domains: Die Konten verweisen darauf.
for eintrag in daten.get("domains", []):
    eintrag = dict(eintrag)
    name = eintrag.pop("name")
    vorhanden = frappe.db.exists("Email Domain", name)
    if vorhanden:
        doc = frappe.get_doc("Email Domain", name)
        doc.update(eintrag)
    else:
        doc = frappe.get_doc({"doctype": "Email Domain", "name": name, **eintrag})

    doc.flags.ignore_mandatory = True
    if vorhanden:
        doc.save(ignore_permissions=True)
    else:
        doc.insert(ignore_permissions=True)

    print(f"  Domain {name}: {'aktualisiert' if vorhanden else 'neu angelegt'}")

for eintrag in daten["accounts"]:
    eintrag = dict(eintrag)
    name = eintrag.pop("name")
    ordner = eintrag.pop("imap_folder", [])

    # Vorhandene werden aktualisiert statt ersetzt: Ein Postfach kann bereits
    # Nachrichten verarbeitet haben, und ein Neuanlegen verlöre den Bezug.
    vorhanden = frappe.db.exists("Email Account", name)
    if vorhanden:
        doc = frappe.get_doc("Email Account", name)
        doc.update(eintrag)
    else:
        doc = frappe.get_doc({"doctype": "Email Account", "name": name, **eintrag})

    doc.set("imap_folder", [])
    for f in ordner:
        doc.append("imap_folder", f)

    doc.flags.ignore_mandatory = True
    if vorhanden:
        doc.save(ignore_permissions=True)
    else:
        doc.insert(ignore_permissions=True)

    print(f"  {name}: {'aktualisiert' if vorhanden else 'neu angelegt'}")

frappe.db.commit()
print(f"{len(daten['accounts'])} Postfach/Postfaecher uebernommen.")
ENDE
    echo "Fertig." >&2
    ;;

  *)
    sed -n '3,20p' "$0" >&2
    exit 1
    ;;
esac
