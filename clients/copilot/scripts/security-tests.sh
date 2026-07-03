#!/bin/bash
# Point d'entrée exécuté DANS le conteneur workspace (COPY'd en /security-tests.sh
# par le Dockerfile). La logique générique vit dans security-tests-common.sh
# (partagé entre clients, COPY'd à côté) ; ce fichier ne fait que charger les
# données et le callback propres à ce client (lib.sh, COPY'd à côté) avant
# de déléguer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=../../../scripts/security-tests-common.sh
source "$SCRIPT_DIR/security-tests-common.sh"
