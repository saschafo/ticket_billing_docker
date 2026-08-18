# Ticket Billing — Docker-Setup (Frappe 16 + ERPNext 16)

*Deutsch · [English](README.en.md)*

Docker-Compose-Setup für die App **ticket_billing** auf **Frappe Framework 16**
und **ERPNext 16**.

Der Build backt Frappe, ERPNext und die App fest ins Image. Es braucht nichts
weiter als Docker — kein bench, kein Python, kein Node auf dem Rechner.

Läuft nativ auf **arm64 (Apple Silicon)** und **amd64**.

Die App selbst liegt in einem eigenen Repo:
[`ticket_billing`](https://github.com/saschafo/ticket_billing).

---

## Inhalt

* [Schnellstart](#schnellstart)
* [Was hier drin ist](#was-hier-drin-ist)
* [Konfiguration](#konfiguration)
* [App-Stand bauen](#app-stand-bauen)
* [Entwicklung: dev-sync.sh](#entwicklung-dev-syncsh)
* [Postfächer sichern: mail-config.sh](#postfächer-sichern-mail-configsh)
* [Neu aufsetzen: neu-aufsetzen.sh](#neu-aufsetzen-neu-aufsetzensh)
* [E-Mail: Voraussetzungen](#e-mail-voraussetzungen)
* [Häufige Aufgaben](#häufige-aufgaben)
* [Aktualisieren](#aktualisieren)
* [Produktivbetrieb](#produktivbetrieb)
* [Aufbau des Images](#aufbau-des-images)
* [Lizenz](#lizenz)

---

## Schnellstart

```bash
cp .env.example .env     # mindestens ADMIN_PASSWORD und DB_PASSWORD setzen
./build.sh               # Image bauen (beim ersten Mal ~20–40 Min)
./ticket.sh up           # Stack starten, Site wird automatisch angelegt
```

Voraussetzung: Docker Engine **23.0+** mit Compose v2 (der Build nutzt
BuildKit-Secrets).

Danach im Browser:

| | |
|---|---|
| URL | <http://ticketbilling.localhost:8080> |
| Benutzer | `Administrator` |
| Passwort | Wert von `ADMIN_PASSWORD` aus der `.env` |

`/` zeigt die Vue-Oberfläche der App, das klassische Frappe-Desk liegt unter
`/app`.

> **Ruf die Anwendung unter dem Site-Namen auf, nicht über `localhost`.**
> Sonst bleibt Realtime stumm: Frappes Socket-Dienst prüft die Sitzung, indem
> er beim Backend zurückfragt, und die Adresse dafür baut er aus dem `Origin`
> des Browsers. `localhost` zeigt im Container auf ihn selbst — die Rückfrage
> läuft ins Leere und jede Verbindung endet mit `Unauthorized: fetch failed`.
> Unter dem Site-Namen greift der Netzwerk-Alias auf dem `frontend`-Dienst.
>
> Aus demselben Grund sollte `HTTP_PUBLISH_PORT` auf `8080` bleiben: Der Port
> steckt im `Origin`, und innen lauscht nginx auf 8080. Ein abweichender Port
> nach außen bricht die Rückfrage wieder.

Stoppen mit `./ticket.sh down` — die Daten bleiben in den Docker-Volumes.

> Nach dem ersten Start ist die Site leer: ERPNext verlangt den
> Einrichtungsassistenten (Firma, Währung, Geschäftsjahr). Wer stattdessen
> sofort ein befülltes System zum Vorführen will, nimmt
> [`./neu-aufsetzen.sh`](#neu-aufsetzen-neu-aufsetzensh).

---

## Was hier drin ist

| Datei | Zweck |
|---|---|
| `Containerfile` | Baut das Image: Frappe 16 + ERPNext 16 + ticket_billing, Assets vorgebaut |
| `compose.yaml` | Der komplette Stack (siehe unten) |
| `.env` / `.env.example` | Sämtliche Konfiguration (Versionen, Repos, Passwörter, Port) |
| `build.sh` | Image-Build, erzeugt `apps.json` aus der `.env` |
| `ticket.sh` | Bedienhilfe: up/down/logs/bench/backup/update/reset |
| `dev-sync.sh` | Lokalen App-Stand in die laufenden Container spielen |
| `mail-config.sh` | Postfach-Einstellungen sichern und zurückspielen |
| `neu-aufsetzen.sh` | Site auf null, Demo-Daten, Postfächer zurück |
| `resources/` | nginx-Template und Entrypoints (aus `frappe_docker`) |
| `apps-local/` | Arbeitskopie des App-Repos bei `APP_SOURCE=local` (nicht im Git dieses Repos) |

### Dienste im Stack

| Dienst | Aufgabe |
|---|---|
| `db` | MariaDB 11.8 |
| `redis-cache`, `redis-queue` | Cache bzw. Job-Queue |
| `configurator` | Einmal-Job: schreibt `common_site_config.json` |
| `create-site` | Einmal-Job: legt die Site an und gleicht `SITE_APPS` ab; bei jedem weiteren Start läuft zusätzlich `bench migrate` |
| `backend` | Gunicorn (Frappe-Webserver) |
| `frontend` | nginx, veröffentlicht Port `8080` |
| `websocket` | Socket.IO für Realtime |
| `scheduler` | Zeitgesteuerte Jobs |
| `queue-short`, `queue-long` | Hintergrund-Worker |

Die Einmal-Jobs sind idempotent: `./ticket.sh up` kann jederzeit erneut
laufen, ohne die Site zu beschädigen.

---

## Konfiguration

Alles läuft über die `.env`. Die wichtigsten Werte:

```dotenv
APP_SOURCE=local             # local = eigener Stand aus apps-local | git = Build klont selbst
APP_REPO_URL=https://github.com/saschafo/ticket_billing
APP_BRANCH=main
APP_NAME=ticket_billing      # muss dem app_name aus hooks.py entsprechen

FRAPPE_BRANCH=version-16     # oder ein festes Tag, z. B. v16.30.0
ERPNEXT_BRANCH=version-16

SITE_NAME=ticketbilling.localhost
SITE_APPS="erpnext ticket_billing"   # Reihenfolge zählt, Quoting Pflicht
SITE_LANG=de                 # Sprache der Site, nur beim Anlegen wirksam
HTTP_PUBLISH_PORT=8080
ADMIN_PASSWORD=...
DB_PASSWORD=...
```

`FRAPPE_SITE_NAME_HEADER` verweist auf `SITE_NAME` und wandert damit
automatisch mit. Dadurch ist die Site unter jedem Hostnamen erreichbar
(`localhost`, der Site-Name selbst, die IP des Rechners). Für
Mehr-Site-Betrieb stattdessen auf `$$host` setzen.

> Stand dort früher ein fester Name, lieferte nginx nach einer Änderung von
> `SITE_NAME` weiterhin die alte Site aus — und die gibt es nicht mehr.
> Ergebnis war **404 auf allem**, ohne jeden Hinweis auf die Ursache. Der
> Site-Name gehört an genau eine Stelle.

Die `.env` enthält Passwörter und ist per `.gitignore` vom Repository
ausgeschlossen. Vorlage ist `.env.example`.

> **`SITE_APPS` muss in Anführungszeichen stehen.** Die Skripte lesen die
> Datei mit `source`; ohne Quoting bricht das an der Leerstelle ab.

### Reihenfolge der Apps

An zwei Stellen, und beide Male muss ERPNext vor `ticket_billing` stehen:

* **`build.sh`** erzeugt daraus `apps.json` — bestimmt, in welcher Reihenfolge
  `bench init` die Apps in die Bench holt.
* **`SITE_APPS`** bestimmt, in welcher Reihenfolge `create-site` sie auf der
  Site installiert.

`ticket_billing` deklariert ERPNext zusätzlich als `required_apps`. Fehlt es,
bricht die Installation mit einer klaren Meldung ab, statt später an fehlenden
Doctypes zu scheitern.

### Sprache der Site

`SITE_LANG` wird **nur beim Anlegen** der Site ausgewertet. `create-site` setzt
den Wert an zwei Stellen, weil Frappe sie unterschiedlich ausliest: die *System
Settings* gelten für angemeldete Nutzer, der Default `lang` für Gäste. Ohne das
läuft eine frische Site auf Englisch — dann greifen weder die Übersetzungen
unter `ticket_billing/translations` noch startet die Vue-Oberfläche auf
Deutsch, denn sie übernimmt die Sitzungssprache über `window.frappe_boot_lang`.

Bei einer bestehenden Site führt die Änderung von `SITE_LANG` zu nichts —
dort im Desk unter *System Settings → Language* umstellen.

---

## App-Stand bauen

Solange das App-Repo nicht öffentlich ist, läuft der Build über
`APP_SOURCE=local`: Die Arbeitskopie liegt in `apps-local/ticket_billing` (ein
eigenständiges Git-Repo) und wird in den Build kopiert.

> **Wichtig:** Auch in diesem Modus klont `bench` aus dem Repo. Ein `git clone`
> überträgt nur **committete** Stände — Änderungen, die nur im Arbeitsbaum
> liegen, landen nicht im Image. `build.sh` warnt darum bei unsauberer
> Arbeitskopie und zeigt den gebauten Commit-Hash an.

Sobald das Repo öffentlich erreichbar ist, lässt sich umstellen:

```dotenv
APP_SOURCE=git
```

Dann klont der Build selbst aus `APP_REPO_URL`. Ist das Repo **privat**, einen
Personal Access Token in `APP_REPO_TOKEN` eintragen — er wird als
BuildKit-Secret übergeben und landet damit **nicht** in den Image-Layern
(`docker image history`).

### Frontend

Das Vue-Frontend der App wird **gebaut mitcommittet**
(`ticket_billing/public/frontend`). Der Docker-Build braucht deshalb keinen
Node-Schritt. Nach Änderungen am Frontend:

```bash
cd apps-local/ticket_billing/ticket_billing/frontend
npm install && npm run build
cd - && git -C apps-local/ticket_billing commit -am "Frontend neu gebaut"
./build.sh --refresh
```

---

## Entwicklung: `dev-sync.sh`

Für den Alltag ist ein Image-Neubau zu langsam. `dev-sync.sh` kopiert den
lokalen App-Stand direkt in die laufenden Container:

```bash
./dev-sync.sh                # kopieren, Cache leeren, Dienste neu starten
./dev-sync.sh --no-restart   # nur kopieren
```

Kopiert wird in **alle** Dienste, die App-Dateien brauchen — `backend`,
`scheduler`, `queue-short`, `queue-long`, `websocket` und `frontend` (nginx
liefert `/assets` aus dem eigenen Container aus).

Zwei Fallstricke, die das Skript für dich abräumt — beide kosten sonst Stunden:

> **Ein Neustart des Backends allein genügt nicht.** Eingehende Mails,
> geplante Aufgaben und Hintergrundjobs laufen in den **Workern**. Bleiben die
> stehen, arbeiten sie weiter mit altem Code, während die API schon den neuen
> hat. Ein neu eingehängter Hook läuft dann ins Leere, obwohl er in der Datei
> steht.

> **Hooks liegen in Redis, nicht nur im Prozessspeicher.** Ein Neustart holt
> eine geänderte `hooks.py` deshalb *nicht* ab: Der Dienst startet neu, liest
> die Hook-Liste aber weiter aus dem Zwischenspeicher. Deshalb läuft vor dem
> Neustart ein `bench clear-cache`.

Beides fällt kaum auf, weil jede Prüfung über `bench` oder die Konsole einen
frischen Prozess startet und den neuen Code sieht — ausgeführt hätte ihn der
Worker.

Neue Doctypes brauchen zusätzlich eine Migration:

```bash
./ticket.sh migrate
```

macOS-Hinweis: Das Skript setzt `COPYFILE_DISABLE=1` und entfernt `._*`.
Ohne das schmuggelt `tar` AppleDouble-Dateien mit, an denen der
Fixture-Import scheitert.

---

## Postfächer sichern: `mail-config.sh`

E-Mail-Konten werden von Hand angelegt und gehören **nicht** zu den
Demo-Daten — ein Entfernen der Demo fasst sie nicht an. Verloren gehen sie
trotzdem leicht: beim Neuaufsetzen der Site, beim Zurücksetzen der Datenbank
oder wenn der Container neu gebaut wird.

```bash
./mail-config.sh export                    # -> mail-accounts.json
./mail-config.sh export --ohne-passwort
./mail-config.sh import                    # zurückspielen
```

Gesichert werden die Konten **und die zugehörige `Email Domain`**. Ohne sie
scheitert das Zurückspielen auf einer frischen Site mit *Could not find
Domain*.

Nicht gesichert werden `uidnext` und `uidvalidity`: Sie beschreiben den Stand
des letzten Abrufs und würden ein neues Postfach an eine Stelle setzen, die
dort nichts bedeutet — im schlimmsten Fall werden vorhandene Mails
übersprungen.

> Die Datei enthält die Postfach-Kennwörter im **Klartext**. Sie wird mit
> Rechten `600` angelegt und ist über `.gitignore` ausgeschlossen. Wer das
> nicht will, nimmt `--ohne-passwort` und trägt sie nach dem Zurückspielen von
> Hand ein.

Ein zurückgespieltes Konto macht einen **Erstabgleich** und holt die letzten
Nachrichten erneut. Nach einem Neuaufsetzen ist das erwünscht — die Tickets
entstehen wieder. Zwei Sites gegen dieselben Postfächer zu betreiben, führt
dagegen zu doppelten Tickets und als gelesen markierter Post.

---

## Neu aufsetzen: `neu-aufsetzen.sh`

Ein Befehl für den ganzen Weg — für Vorführungen und Tests:

```bash
./neu-aufsetzen.sh          # fragt nach
./neu-aufsetzen.sh --ja     # ohne Rückfrage
```

1. Postfächer sichern (solange die alte Site noch läuft)
2. Volumes löschen, Site neu anlegen
3. **Lokalen App-Stand einspielen und migrieren**
4. ERPNext-Assistenten ohne Rückfragen abschließen
5. Demo-Daten einspielen
6. Postfächer zurückspielen

> **Das löscht die Datenbank vollständig.** Echte Tickets, Mailverläufe und
> Rechnungen sind danach weg — und eingegangene Mails kommen nicht zurück,
> weil die Postfächer nur Ungelesenes liefern.

Anpassbar über die `.env` bzw. die Umgebung:

```dotenv
DEMO_COMPANY=Musterfirma
DEMO_COMPANY_ABBR=MF
DEMO_COUNTRY=Germany
DEMO_CURRENCY=EUR
DEMO_TIMEZONE=Europe/Berlin
DEMO_COA=SKR04 mit Kontonummern
DEMO_FY_YEAR=2026
```

Zwei Eigenheiten des Einrichtungsassistenten, die das Skript abfängt:

* **Der Kontenrahmen muss exakt einem hinterlegten Namen entsprechen.** Passt
  er nicht, legt ERPNext die Firma an und stürzt danach in `on_update` ab —
  der Assistent fängt das ab und meldet trotzdem `status: ok`. Deshalb prüft
  das Skript auf die *Firma*, nicht auf die Rückmeldung. Gültige Werte für
  Deutschland: `SKR04 mit Kontonummern`, `SKR03 mit Kontonummern`, `Standard`,
  `Standard with Numbers`.
* **Ohne ausdrückliche Daten entsteht ein ungültiges Geschäftsjahr**
  („End Date should be one year after Start Date"). Der Fehler wird
  protokolliert und übersprungen — zurück bliebe ein System, in dem sich keine
  Rechnung schreiben lässt. Das Skript übergibt die Daten und trägt das
  Geschäftsjahr notfalls nach.

Ein gescheiterter Assistentenlauf hinterlässt die Site als „eingerichtet" und
vermerkt Apps als erledigt; ein zweiter Versuch überspringt sie dann
schweigend. Das Skript setzt den Schalter deshalb vorher zurück.

---

## E-Mail: Voraussetzungen

Eingehende Post braucht je Abteilung ein `Email Account` mit gesetztem
`tb_department`, und bei IMAP muss `append_to = Issue` am **Ordner** stehen,
nicht am Konto.

Ausgehende Post wird von großen Anbietern abgelehnt, wenn die Absenderdomain
sich nicht ausweisen kann. Gmail verlangt seit 2024 **SPF oder DKIM**:

```
550-5.7.26 Your email has been blocked because the sender is unauthenticated.
550-5.7.26 Gmail requires all senders to authenticate with either SPF or DKIM.
```

Im DNS der Absenderdomain gehören deshalb ein `A`-Record, ein SPF-Eintrag, der
den **tatsächlich sendenden** Server nennt, ein DKIM-Schlüssel unter
`default._domainkey` und ein DMARC-Eintrag. Details stehen in der
[App-README](https://github.com/saschafo/ticket_billing#e-mail).

Zwei Stolperstellen aus der Praxis: Ein SPF-Eintrag, der noch auf einen
früheren Mailanbieter zeigt, und eine DNS-Zone, die gar nicht beim eigenen
Server liegt — dann ändert man im Serverpanel eine Zone, die niemand abfragt.
Prüfen mit `dig +short TXT <domain>` gegen die zuständigen Nameserver.

Außerdem sollte `host_name` gesetzt sein, sonst zeigen Abmelde- und
Anhanglinks in ausgehenden Mails ins Leere:

```bash
./ticket.sh bench --site ticketbilling.localhost set-config host_name https://tickets.example.org
```

---

## Häufige Aufgaben

```bash
./ticket.sh status                 # Container-Status
./ticket.sh logs backend           # Logs eines Dienstes
./ticket.sh bench --site ticketbilling.localhost list-apps
./ticket.sh migrate                # Schema-Migration nachziehen
./ticket.sh backup                 # Backup inkl. Dateien nach ./backups/
./ticket.sh console                # Frappe-Python-Konsole
./ticket.sh shell                  # Shell im Backend-Container
./ticket.sh reset                  # ALLES löschen (fragt nach)
```

---

## Aktualisieren

Das Image ist unveränderlich. Neue App-Stände, neue Frappe-/ERPNext-Versionen
und Schema-Änderungen kommen ausschließlich über einen neuen Build herein — die
Daten liegen davon getrennt in Docker-Volumes und bleiben unberührt.

```bash
./ticket.sh update
```

Das erledigt vier Schritte:

1. **Sicherung** der Site inklusive Dateien nach `backups/`
2. **Neubau** des Images mit `--refresh` — Frappe, ERPNext und die App werden
   frisch geklont, der Rest kommt aus dem Layer-Cache
3. **Neustart** der Container mit dem neuen Image
4. **`bench migrate`** — läuft automatisch im `create-site`-Job, sobald eine
   Site existiert

Schritt 1 lässt sich mit `./ticket.sh update --no-backup` überspringen. Ich
würde es nicht tun: `bench migrate` führt Patches aus, und ein mittendrin
gescheiterter Patch hinterlässt eine halb migrierte Datenbank.

### Zurück auf einen früheren Stand

Jeder Build setzt zwei Tags: den beweglichen `:16` und einen festen mit dem
App-Commit, etwa `:16-dc31481`. Nur deshalb gibt es überhaupt einen Rückweg —
sonst hätte der nächste Build den vorherigen Stand überschrieben.

```bash
docker images ticket-billing/frappe     # verfügbare Stände ansehen
```

Dann in der `.env` den gewünschten Tag eintragen und neu starten:

```dotenv
CUSTOM_TAG=16-dc31481
```

```bash
./ticket.sh up
```

Wichtig: Das setzt **nur den Code** zurück, nicht die Datenbank. Hat eine
Migration das Schema bereits verändert, kommt der alte Code damit
möglicherweise nicht zurecht. Für einen vollständigen Rückweg zusätzlich die
Sicherung einspielen:

```bash
./ticket.sh bench --site ticketbilling.localhost restore backups/<datei>.sql.gz
```

### Versionen festlegen

`FRAPPE_BRANCH=version-16` und `ERPNEXT_BRANCH=version-16` sind **bewegliche
Branches** — jeder Build mit `--refresh` holt den jeweils neuesten Stand. Für
reproduzierbare Builds stattdessen Tags eintragen:

```dotenv
FRAPPE_BRANCH=v16.30.0
ERPNEXT_BRANCH=v16.30.0
```

Frappe und ERPNext gehören dabei auf denselben Major-Stand. Dasselbe gilt für
`APP_BRANCH`, dort ist auch ein Tag oder ein Commit möglich.

---

## Produktivbetrieb

Für den Einsatz auf einem Server zusätzlich beachten:

1. **Passwörter** in der `.env` ersetzen (`ADMIN_PASSWORD`, `DB_PASSWORD`).
2. **TLS**: einen Reverse Proxy (Traefik, Caddy, nginx-proxy) vor `frontend`
   setzen und `HTTP_PUBLISH_PORT` nur an `127.0.0.1` binden. Fertige Overrides
   dafür liegen im Upstream-Repo `frappe_docker` unter `overrides/`.
3. **Site-Name** auf die echte Domain setzen (`SITE_NAME`,
   `FRAPPE_SITE_NAME_HEADER`) — der Site-Ordner muss so heißen wie die Domain.
4. **`host_name`** setzen, damit Links in ausgehenden Mails stimmen.
5. **Registry**: Image einmal bauen, pushen und auf dem Server nur noch ziehen —
   `CUSTOM_IMAGE=ghcr.io/<user>/ticket-billing`, `PULL_POLICY=always`.
6. **Backups** regelmäßig wegsichern (`./ticket.sh backup` oder das
   `compose.backup-cron.yaml`-Override aus `frappe_docker`).
7. **Keine Demo-Daten.** Solange sie installiert sind, kommt jeder ohne
   Passwort in die Anwendung.

---

## Aufbau des Images

`Containerfile` stammt aus dem offiziellen `frappe_docker` (Variante `custom`).
Abweichung: eine `COPY`-Zeile, die `apps-local/` in die Build-Stage holt (für
`APP_SOURCE=local`; bei `git` ist der Ordner leer und wirkungslos).

Zweite Abweichung, in `resources/core/nginx/nginx-template.conf`: Der
`/socket.io`-Block reicht das echte `Origin` durch, statt es fest auf den
Site-Namen zu setzen. Frappes Socket-Authentifizierung vergleicht `Origin` mit
`Host` — mit dem Originalwert scheitert jede Verbindung über
`http://localhost:8080` mit „Invalid origin", und Realtime bleibt still, ohne
dass die Oberfläche etwas meldet. Das durchgereichte Origin ist zugleich die
schärfere Prüfung: Eine fremde Seite wird damit abgewiesen, beim festen Wert
wäre sie durchgerutscht.

---

## Lizenz

[GNU Affero General Public License v3.0](LICENSE)

Copyright (C) 2026 Sascha Böhm Software & App, Inhaber Sascha Böhm

Das Setup stützt sich auf [`frappe_docker`](https://github.com/frappe/frappe_docker)
(MIT) und betreibt ERPNext (GPL-3.0). Für abweichende Konditionen wenden Sie
sich an den Rechteinhaber.
