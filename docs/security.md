# Sécurité

Détail complet des mesures de sécurité implémentées, de ce qui n'est pas couvert, et des bonnes pratiques d'exploitation. Pour un résumé rapide, voir la section Sécurité du [README](../README.md).

---

## Mesures de sécurité implémentées

| **Catégorie** | **Mesure** | **Où** |
|--------------|------------|--------|
| **Isolation réseau** | Aucune route par défaut vers l'extérieur | `workspace`, réseau `--internal` |
| **Isolation réseau** | Seul point d'accès réel à internet | `gateway` (double-attaché) |
| **Filtrage** | Allowlist de domaines | Squid ACL `dstdomain`, dans `gateway` |
| **Défense en profondeur** | Verrouillage de l'egress du gateway lui-même | nftables (`GATEWAY_HARDENED=1`) |
| **Défense en profondeur** | Le gateway ne peut jamais router entre ses deux interfaces | chaîne `forward` nftables vide, `ip_forward=0` vérifié au démarrage |
| **Isolation utilisateur** | Non-root partout | `workspace` (UID 1000), `gateway` (nobody) |
| **Isolation utilisateur** | Abandon définitif des privilèges | `gateway` : `su-exec nobody` après chargement des règles réseau |
| **Isolation filesystem** | Lecture seule | `--read-only` + tmpfs sur les deux conteneurs |
| **Capacités** | `--cap-drop=ALL` sur les deux conteneurs | capacités ajoutées seulement temporairement sur le gateway durci |
| **Cohérence CLI / VS Code** | Le contrat d'isolation du workspace (`--userns`, `--cap-drop`, `--read-only`, `--tmpfs`, `--security-opt`), l'URL du proxy et `IA_CLIENT` sont générés depuis une source unique (`WORKSPACE_SECURITY_ARGS`/`proxy_url()`/`CLIENT_NAME`, `scripts/orchestrator.py`) — les deux chemins de lancement ne peuvent pas diverger | `run.sh shell`/`test` (`podman run` direct) et `.devcontainer/devcontainer.json` (VS Code), rendu par `render_devcontainer()` |
| **Installation de dépendances** | `pip install --user` sans sudo | `workspace` |
| **Secrets** | `podman secret` (type=env), repli `--env-file .env` | `run.sh secrets` pour le statut ; jamais `-e CLE=valeur` |
| **Audit** | Tests automatiques exécutés contre le vrai gateway | `run.sh test` / `security-tests.sh` |
| **Isolation projet** | Réseau/conteneurs/images overlay/paquets installés scopés par projet | voir [Isolation entre projets](architecture.md#isolation-entre-projets) |
| **Auto-protection** | `ia-dev-containers/` remonté en lecture seule sur lui-même dans `/workspace` (par défaut) | `run.sh doctor` pour le statut, `run.sh test` pour la vérification ; voir [Architecture](architecture.md#workspace-est-un-accès-direct-au-projet-hôte-pas-une-copie-isolée) |
| ⚠️ **Non couvert** | `/workspace` = bind-mount du projet réel, pas un volume vide (au-delà de `ia-dev-containers/` lui-même, protégé ci-dessus) | voir [Architecture](architecture.md#workspace-est-un-accès-direct-au-projet-hôte-pas-une-copie-isolée) |
| ⚠️ **Vérifié rootless uniquement** | `security-tests.sh` sonde la passerelle du bridge (`10.x.x.1`) sur les ports 22/80 et attend un échec. En Podman **rootful**, cette IP est l'hôte réel : tout service y écoutant sur `0.0.0.0` serait joignable depuis le workspace malgré `--internal` | `run.sh test`, section 3 (« Isolation réseau ») |
| ⚠️ **Affaibli sous SELinux** (Fedora/RHEL) | `workspace` tourne avec `--security-opt=label=disable` (confinement SELinux désactivé pour ce conteneur) | nécessaire pour que le bind-mount `/workspace` soit accessible sans relabeler les fichiers réels du projet sur disque (l'alternative `:Z` le ferait, effet de bord permanent hors du sandbox) ; no-op sur les hôtes sans SELinux (macOS, Windows, la plupart des distributions Linux hors Fedora/RHEL) |
| ⚠️ **Non vérifié en session VS Code réelle** | `initializeCommand` (`./scripts/run.sh up`) dans `devcontainer.json` suppose que VS Code l'exécute avec pour cwd le dossier ouvert (`clients/<client>/`) — validé seulement par lecture du JSON généré et de la doc devcontainers, pas par une ouverture VS Code réelle | si l'ouverture échoue à cause de cette ligne, retirez `initializeCommand` de `scripts/devcontainer-skeleton.json.template` et revenez à l'étape manuelle (`cd clients/<client> && ./scripts/run.sh up` avant d'ouvrir VS Code) |

Les URLs autorisées par défaut sont spécifiques à chaque client — voir [clients/mistral-vibe/README.md](../clients/mistral-vibe/README.md#-urls-autorisées-par-défaut) et [clients/copilot/README.md](../clients/copilot/README.md#-domaines-autorisés-par-défaut).

> ⚠️ **Limite connue** : l'allowlist par domaine *réduit* le risque d'exfiltration, elle ne l'élimine pas. Des domaines autorisés comme `github.com` ou `huggingface.co` exposent des surfaces en écriture (gists, issues, upload de modèles) qui restent un vecteur résiduel.
>
> ⚠️ **Contrainte assumée** : seuls les remotes git en **HTTPS** fonctionnent. Le SSH (port 22) n'est pas relayé par le gateway.

---

## Bonnes pratiques

1. **Secrets** : `podman secret create <nom> -` plutôt que `.env` (`.env` reste un repli valide) — le gain vérifié est que la valeur n'apparaît jamais dans `podman inspect`, ce n'est pas un chiffrement au repos. Jamais de `-e CLE=valeur` sur la ligne de commande. `./scripts/run.sh secrets` affiche le statut.
2. **Mettez à jour régulièrement** les images de base (`podman build --no-cache`). Toute modification de `gateway-base/certs/` ou `workspace-base/certs/` (CA d'entreprise, voir [Dépannage](troubleshooting.md#réseau-dentreprise-avec-inspection-tls-proxy-corporate)) nécessite le même rebuild forcé.
3. **Ne contournez jamais le gateway** : c'est la seule protection contre l'exfiltration. Pour un nouveau besoin réseau, ajoutez le domaine à l'allowlist plutôt que de désactiver le filtrage.
4. **`GATEWAY_HARDENED=1` (Phase durcie) reste opt-in, pas activé par défaut délibérément.** Coût mesuré négligeable (~10ms au démarrage) sur Linux natif, où c'est un pur gain de défense en profondeur (nftables sur l'egress du gateway, au cas où l'allowlist applicative serait un jour contournée). Mais la Phase durcie démarre le conteneur root-in-userns avec `--cap-add=NET_ADMIN,NET_RAW,SETUID,SETGID` (`entrypoint.sh` a `set -eu` : si `nft -f` échoue ou si l'environnement refuse ces capacités, le gateway crashe au démarrage plutôt que de dégrader gracieusement) — un chemin jamais exercé en conditions réelles sur macOS/Windows (`podman machine`), déjà étiquetés expérimentaux (voir [tableau Plateformes hôte](../README.md#-plateformes-hôte)). Activez-la si vous tournez sur Linux natif et voulez cette couche supplémentaire ; sur macOS/Windows, ou en cas de doute, le défaut `=0` (nobody direct, zéro capacité ajoutée) reste le choix le plus robuste — l'allowlist Squid est de toute façon la protection principale, pas cette défense en profondeur.
