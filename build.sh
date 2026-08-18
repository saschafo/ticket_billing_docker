#!/usr/bin/env bash
# =============================================================================
# Baut das Frappe-16-Image inklusive ERPNext 16 und der App ticket_billing.
#
#   ./build.sh              # normaler Build (nutzt Docker-Layer-Cache)
#   ./build.sh --no-cache   # kompletter Neubau
#   ./build.sh --refresh    # Frappe/App-Layer neu holen, Rest aus dem Cache
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

CUSTOM_IMAGE=${CUSTOM_IMAGE:-ticket-billing/frappe}
CUSTOM_TAG=${CUSTOM_TAG:-16}
FRAPPE_PATH=${FRAPPE_PATH:-https://github.com/frappe/frappe}
FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-16}
ERPNEXT_REPO_URL=${ERPNEXT_REPO_URL:-https://github.com/frappe/erpnext}
ERPNEXT_BRANCH=${ERPNEXT_BRANCH:-version-16}
APP_NAME=${APP_NAME:-ticket_billing}
APP_BRANCH=${APP_BRANCH:-main}
APP_SOURCE=${APP_SOURCE:-local}
APP_REPO_TOKEN=${APP_REPO_TOKEN:-}

if [[ -z "${APP_REPO_URL:-}" ]]; then
  echo "FEHLER: APP_REPO_URL ist in .env nicht gesetzt." >&2
  exit 1
fi

REFRESH=0
BUILD_ARGS=(
  --build-arg "FRAPPE_PATH=${FRAPPE_PATH}"
  --build-arg "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
)
[[ -n "${PYTHON_VERSION:-}" ]] && BUILD_ARGS+=(--build-arg "PYTHON_VERSION=${PYTHON_VERSION}")
[[ -n "${NODE_VERSION:-}" ]] && BUILD_ARGS+=(--build-arg "NODE_VERSION=${NODE_VERSION}")

for arg in "$@"; do
  case "$arg" in
    --no-cache) BUILD_ARGS+=(--no-cache) ;;
    # CACHE_BUST invalidiert genau den Layer, der Frappe und die Apps klont.
    --refresh)  REFRESH=1; BUILD_ARGS+=(--build-arg "CACHE_BUST=$(date +%s)") ;;
    *)          BUILD_ARGS+=("$arg") ;;
  esac
done

# -----------------------------------------------------------------------------
# App-Quelle bestimmen
#   local : Arbeitskopie unter apps-local/<app> wird ins Image kopiert.
#           Braucht keine Zugangsdaten im Container (das Klonen macht der Host).
#   git   : Der Container klont direkt aus APP_REPO_URL. Für öffentliche
#           Repos (GitHub) ohne alles, für private mit APP_REPO_TOKEN.
# -----------------------------------------------------------------------------
LOCAL_APPS_DIR="apps-local"
mkdir -p "$LOCAL_APPS_DIR"

case "$APP_SOURCE" in
  local)
    APP_CHECKOUT="${LOCAL_APPS_DIR}/${APP_NAME}"
    # Das Klonen macht der Host. Solange das Repo privat ist, geht das per SSH
    # bequemer als per HTTPS -- dafür APP_REPO_URL_HOST. Ist die Variable leer,
    # wird APP_REPO_URL verwendet.
    HOST_CLONE_URL="${APP_REPO_URL_HOST:-$APP_REPO_URL}"
    if [[ ! -d "${APP_CHECKOUT}/.git" ]]; then
      echo "Hole Arbeitskopie nach ${APP_CHECKOUT} ..."
      rm -rf "$APP_CHECKOUT"
      git clone --branch "$APP_BRANCH" "$HOST_CLONE_URL" "$APP_CHECKOUT"
    elif [[ $REFRESH -eq 1 ]]; then
      # Ohne Remote (frisch angelegtes, noch nicht gepushtes Repo) gibt es
      # nichts zu holen -- dann bleibt die Arbeitskopie einfach stehen.
      if git -C "$APP_CHECKOUT" remote get-url origin >/dev/null 2>&1; then
        echo "Aktualisiere Arbeitskopie ${APP_CHECKOUT} ..."
        git -C "$APP_CHECKOUT" fetch origin "$APP_BRANCH"
        git -C "$APP_CHECKOUT" checkout "$APP_BRANCH"
        git -C "$APP_CHECKOUT" merge --ff-only "origin/${APP_BRANCH}"
      else
        echo "Hinweis: ${APP_CHECKOUT} hat kein 'origin'-Remote, nichts zu holen."
      fi
    fi
    # bench klont aus dem Verzeichnis -- ein git clone sieht nur Committetes.
    # Nicht committete Änderungen landen also NICHT im Image.
    if [[ -n "$(git -C "$APP_CHECKOUT" status --porcelain)" ]]; then
      echo
      echo "WARNUNG: ${APP_CHECKOUT} hat nicht committete Änderungen." >&2
      git -C "$APP_CHECKOUT" status --short >&2
      echo "Der Build klont aus dem Repo und übernimmt nur Committetes." >&2
      echo "Erst committen, dann bauen." >&2
      echo
    fi
    APP_URL="/opt/frappe/apps-local/${APP_NAME}"
    APP_COMMIT=$(git -C "$APP_CHECKOUT" rev-parse --short HEAD)
    APP_INFO="lokal aus ${APP_CHECKOUT} @ ${APP_COMMIT} (Branch ${APP_BRANCH})"
    ;;
  git)
    APP_URL="$APP_REPO_URL"
    if [[ -n "$APP_REPO_TOKEN" ]]; then
      APP_URL="${APP_REPO_URL/https:\/\//https://${APP_REPO_TOKEN}@}"
    fi
    # Commit-Kürzel des Branch-Kopfes, damit das Image eindeutig benannt
    # werden kann. Schlägt die Abfrage fehl, wird nur der Haupt-Tag gesetzt.
    # Mit APP_URL statt APP_REPO_URL: Bei einem privaten Repo antwortet die
    # nackte Adresse nicht, APP_COMMIT bliebe leer -- und ohne Commit gibt es
    # keinen festen Tag :16-<commit>, also auch keinen Rueckweg auf einen
    # frueheren Stand.
    APP_COMMIT=$(git ls-remote "$APP_URL" "refs/heads/${APP_BRANCH}" 2>/dev/null | cut -c1-7)
    APP_INFO="${APP_REPO_URL} @ ${APP_BRANCH}"
    [[ -n "$APP_COMMIT" ]] && APP_INFO="${APP_INFO} (${APP_COMMIT})"
    [[ -n "$APP_REPO_TOKEN" ]] && APP_INFO="${APP_INFO} (mit Token)"
    ;;
  *)
    echo "FEHLER: APP_SOURCE muss 'local' oder 'git' sein (ist: ${APP_SOURCE})." >&2
    exit 1
    ;;
esac

# apps.json wird aus der .env erzeugt und als BuildKit-Secret übergeben,
# damit ein evtl. Token nicht in "docker image history" auftaucht.
#
# Die Reihenfolge ist bindend: bench installiert die Apps in genau dieser
# Folge in die Bench. ERPNext muss vor ticket_billing stehen, weil die App
# auf ERPNext-Doctypes aufsetzt.
APPS_JSON=$(mktemp)
trap 'rm -f "$APPS_JSON"' EXIT
cat >"$APPS_JSON" <<EOF
[
  {
    "url": "${ERPNEXT_REPO_URL}",
    "branch": "${ERPNEXT_BRANCH}"
  },
  {
    "url": "${APP_URL}",
    "branch": "${APP_BRANCH}"
  }
]
EOF

# Zusaetzlicher, eindeutiger Tag mit dem App-Commit. Der bewegliche Tag
# (:16) zeigt immer auf den neuesten Build, der Commit-Tag bleibt bestehen --
# damit ist ein Rueckweg auf einen frueheren Stand ueberhaupt erst moeglich.
VERSION_TAG=""
[[ -n "${APP_COMMIT:-}" ]] && VERSION_TAG="${CUSTOM_TAG}-${APP_COMMIT}"

echo "-------------------------------------------------------------"
echo " Image      : ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
[[ -n "$VERSION_TAG" ]] && \
echo "              ${CUSTOM_IMAGE}:${VERSION_TAG}"
echo " Frappe     : ${FRAPPE_PATH} @ ${FRAPPE_BRANCH}"
echo " ERPNext    : ${ERPNEXT_REPO_URL} @ ${ERPNEXT_BRANCH}"
echo " ${APP_NAME}: ${APP_INFO}"
echo "-------------------------------------------------------------"

TAGS=(--tag "${CUSTOM_IMAGE}:${CUSTOM_TAG}")
[[ -n "$VERSION_TAG" ]] && TAGS+=(--tag "${CUSTOM_IMAGE}:${VERSION_TAG}")

DOCKER_BUILDKIT=1 docker build \
  "${BUILD_ARGS[@]}" \
  --secret "id=apps_json,src=${APPS_JSON}" \
  "${TAGS[@]}" \
  --file Containerfile \
  .

echo
echo "Fertig: ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
if [[ -n "$VERSION_TAG" ]]; then
  echo "        ${CUSTOM_IMAGE}:${VERSION_TAG}  (fuer einen Rueckweg notieren)"
fi
echo "Weiter mit:  ./ticket.sh up"
