# Architecture

Détail complet de l'architecture à deux conteneurs, des avertissements sur le bind-mount, de l'auto-protection, de la structure du projet et de l'isolation entre projets. Pour une vue d'ensemble rapide, voir la section Architecture en bref du [README](../README.md).

---

## Deux conteneurs, jamais un seul

Le sandbox repose sur **deux conteneurs séparés** :

- **`gateway`** : le seul conteneur avec un accès réseau réel. Fait tourner Squid, applique l'allowlist de domaines. Ne contient jamais de code du CLI IA.
- **`workspace`** : exécute le CLI IA (non fiable par hypothèse). Attaché **uniquement** à un réseau Podman `--internal`, qui n'a **aucune route par défaut vers l'extérieur** — c'est ça, et rien d'autre, qui garantit qu'il ne peut rien joindre en direct.

```
                  réseau "podman" (uplink réel)
                          │
                    ┌─────▼─────┐
                    │  gateway  │  Squid + allowlist de domaines
                    └─────┬─────┘
                          │ réseau interne dédié au projet (--internal, sans route sortante)
                    ┌─────▼─────┐
                    │ workspace │  CLI IA, cap-drop=ALL, read-only, non-root
                    │           │  /workspace = bind-mount du projet hôte
                    └───────────┘
```

**Pourquoi cette séparation ?** Un seul conteneur ne peut pas offrir à la fois un vrai accès réseau pour le proxy *et* une garantie noyau que le workload ne peut pas le contourner (`--network=none` empêche les deux à la fois ; sans lui, `HTTP_PROXY` n'est qu'une convention qu'un process hostile peut ignorer). Séparer les deux rôles dans deux conteneurs résout ce dilemme : le `workspace` n'a physiquement aucune interface vers l'extérieur, quel que soit le comportement du CLI IA qu'il exécute.

Cette architecture est **construite et testée réellement** (Podman 5.8.3, réseau `--internal`, résolution DNS entre conteneurs via aardvark-dns) — pas seulement documentée sur le papier. Deux niveaux sont disponibles pour le gateway :

- **Phase simple** (`GATEWAY_HARDENED=0`, par défaut) : le gateway tourne directement en utilisateur `nobody`, sans capacité particulière.
- **Phase durcie** (`GATEWAY_HARDENED=1`) : le gateway démarre root-in-userns, charge des règles **nftables** verrouillant sa propre sortie (ports 80/443 uniquement, blocage des plages RFC1918 et de l'IP de métadonnées cloud `169.254.169.254`), vérifie que `net.ipv4.ip_forward=0`, puis abandonne définitivement ses privilèges vers `nobody` avant de lancer Squid.

---

## `/workspace` est un accès direct au projet hôte, pas une copie isolée

Le CLI IA lit et écrit les vrais fichiers du projet (bind-mount de la racine du projet, pas un volume Podman vide). C'est un choix assumé — le CLI doit pouvoir modifier le code, committer, lancer les outils du projet — mais ça élargit la surface par rapport à un volume vide : un fichier écrit par le CLI IA (hook git, script de build, `package.json`, config CI) peut ensuite s'exécuter **côté hôte** la prochaine fois que vous lancez une commande normale dans ce projet. L'isolation réseau/capacités/utilisateur du sandbox protège la machine hôte pendant que le CLI tourne ; elle ne protège pas rétroactivement le projet contre un fichier malveillant qu'il y aurait laissé. Revoyez les diffs comme vous le feriez pour toute contribution externe.

### Cas particulier : `ia-dev-containers/` lui-même est à l'intérieur du bind-mount

Puisque cette copie est déposée à la racine du projet, elle fait partie de `/workspace`. **Auto-protection par défaut** : un second bind-mount, en lecture seule, est empilé sur `ia-dev-containers/` à l'intérieur du conteneur `workspace` — le CLI IA peut lire sa propre config sandbox (donc `git status`/`git add` lancés depuis le workspace restent normaux sur ces fichiers, qui suivent le dépôt du projet hôte), mais ne peut **plus** modifier `gateway/config/allowed-urls.txt` (élargir sa propre allowlist réseau), `scripts/run.sh`/`lib.sh`, ou les `Dockerfile` en écriture directe. Comme `build_images()` reconstruit l'overlay gateway/workspace à **chaque** `run.sh up`, c'était auparavant un vecteur direct : une allowlist modifiée aurait été reprise (et un script modifié réexécuté avec vos privilèges) dès le lancement suivant.

`./scripts/run.sh doctor` affiche l'état de cette auto-protection (`active`, `désactivée`, ou `non applicable`) ; `./scripts/run.sh test` la vérifie (lecture OK, écriture bloquée). Cette protection est automatiquement désactivée dans deux cas où elle n'a pas de sens : la copie a été relocalisée hors de l'arborescence du projet (voir plus bas), ou `ia-dev-containers` est lui-même le projet sandboxé (dogfooding). Une échappatoire explicite existe pour le cas rare où le CLI IA doit modifier sa propre config sandbox depuis l'intérieur : `IA_SELF_MOUNT_RW=1 ./scripts/run.sh up`.

Cette protection ne couvre que l'**écriture** sur `ia-dev-containers/` lui-même — le reste du projet hôte reste en bind-mount lecture-écriture normal (le CLI doit pouvoir modifier le code, committer, lancer les outils du projet), avec les mêmes implications qu'avant : un fichier écrit par le CLI IA ailleurs dans `/workspace` (hook git, script de build, `package.json`, config CI) peut ensuite s'exécuter côté hôte. Revoyez les diffs comme vous le feriez pour toute contribution externe. Même chose pour `clients/*/.env` s'il existe : la lecture directe par le CLI IA n'est pas changée par cette auto-protection (le mount lecture seule le laisse toujours lisible, pas une fuite nouvelle puisque le CLI a de toute façon la valeur via son environnement) — une raison de plus de préférer `podman secret` (dont le stockage vit hors du mount) pour tout secret que le CLI n'a pas besoin de *lire lui-même* en dehors de son usage normal.

### Relocaliser `ia-dev-containers/` hors du projet

Si vous préférez éliminer entièrement `ia-dev-containers/` du bind-mount plutôt que de le protéger en lecture seule (par exemple pour empêcher toute lecture, pas seulement l'écriture), l'option de relocalisation reste disponible : déplacer physiquement `ia-dev-containers/` hors de l'arborescence du projet (ex. `~/.ia-sandboxes/mon-projet/ia-dev-containers/`) et lancer avec `IA_PROJECT_ROOT=/chemin/vers/mon-projet ./scripts/run.sh up` — **vérifié** : dans ce cas, `/workspace` ne contient plus `ia-dev-containers/` du tout, le CLI IA n'y a même pas accès en lecture, et l'auto-protection ci-dessus devient un no-op (rien à protéger).

---

## Structure du projet

```bash
mon-projet/                        # 🎯 Le projet que vous voulez sandboxer
├── ia-dev-containers/              # Cette copie, déposée à la racine
│   ├── gateway-base/               # 📦 Image générique du gateway (Squid, nftables)
│   │   ├── Dockerfile
│   │   ├── config/squid.conf       # ACL génériques, pas d'allowlist en dur
│   │   └── scripts/{entrypoint.sh, gateway.nft, gateway-checks.sh}
│   │
│   ├── workspace-base/             # 📦 Image générique du workspace (CLI IA)
│   │   ├── Dockerfile
│   │   └── scripts/entrypoint.sh
│   │
│   ├── scripts/                    # 🧩 Orchestrateur générique, partagé par tous les clients
│   │   ├── orchestrator.py         # Python, côté hôte uniquement — up|shell|test|down|secrets|doctor (main()), gabarits de noms, rendu devcontainer.json
│   │   ├── test_orchestrator.py    # Tests rapides sans Podman de orchestrator.py (python3 scripts/test_orchestrator.py)
│   │   ├── security-tests.sh       # Batterie de tests générique, copiée dans l'image workspace, source /lib.sh (bash, tourne dans le conteneur)
│   │   └── devcontainer-skeleton.json.template  # Squelette VS Code partagé, rendu par render_devcontainer()
│   │
│   ├── clients/                    # 🎯 Adaptateurs par client IA (seulement ce qui varie)
│   │   ├── mistral-vibe/           # Adaptateur pour Mistral Vibe CLI (Python)
│   │   │   ├── gateway/            # Overlay : allowlist de domaines spécifique
│   │   │   │   ├── Dockerfile
│   │   │   │   └── config/allowed-urls.txt
│   │   │   ├── workspace/          # Overlay : Python 3 + pip
│   │   │   │   └── Dockerfile
│   │   │   ├── scripts/
│   │   │   │   ├── lib.sh          # Adaptateur bash : CLIENT_NAME, volume de paquets, domaines testés, SECRETS, callback de test, cosmétique VS Code (DEVCONTAINER_*)
│   │   │   │   └── run.sh          # Point d'entrée mince : source lib.sh, construit les arguments CLI, exec python3 orchestrator.py
│   │   │   ├── .devcontainer/
│   │   │   │   └── devcontainer.json      # Généré par `run.sh up` depuis scripts/devcontainer-skeleton.json.template — pas suivi par git
│   │   │   ├── .env.example        # Modèle pour les secrets (MISTRAL_API_KEY, ...)
│   │   │   └── README.md
│   │   │
│   │   └── copilot/                # Adaptateur pour GitHub Copilot CLI (Node.js)
│   │       └── (même structure que mistral-vibe/)
│   │
│   └── .gitignore                  # Ignore .env réels et devcontainer.json généré
│
├── (vos fichiers de projet, inchangés)
└── ...
```

`gateway-base/` et `workspace-base/` sont partagés par les deux clients **et par tous les projets** (aucun contenu spécifique à un projet, un seul tag global profite du cache de layers). `gateway-base` reste sur Alpine **3.24** (pin délibéré, pas `latest` : voir le commentaire en tête du Dockerfile — reproductibilité des builds et audit des versions, pas de cible mobile sur des composants de sécurité comme Squid/nftables). `workspace-base` est sur **Debian bookworm-slim** (glibc) : `@github/copilot` (client Copilot) segfaute de façon reproductible sur un binaire natif lié à musl (Alpine), y compris hors de tout durcissement du sandbox — bug upstream connu (voir le commentaire en tête de `workspace-base/Dockerfile`) — d'où la bascule sur glibc, partagée avec mistral-vibe (Python/pip, sans régression). Le client Copilot copie le runtime Node officiel (`node:22-bookworm-slim`) plutôt que d'utiliser le paquet `nodejs` de Debian (absent/trop ancien dans les dépôts stables) — voir `clients/copilot/workspace/Dockerfile`.

Les images overlay (gateway/workspace de chaque client), le réseau `--internal` et les conteneurs sont en revanche scopés **par projet** (voir [Isolation entre projets](#isolation-entre-projets) plus bas) : deux copies de `ia-dev-containers` dans deux projets différents ne se marchent jamais dessus, y compris lancées en même temps.

---

## Isolation entre projets

Chaque copie de `ia-dev-containers` déduit son **nom de projet** (`PROJECT_NAME`) du nom du dossier qui la contient, et l'utilise pour scoper toutes les ressources Podman qu'elle crée — pas de registre central, pas de coordination requise entre projets :

| Ressource | Scope | Pourquoi |
|---|---|---|
| Réseau `--internal` (subnet `/24` dans `10.89.0.0/16`) | par (projet, client) | Podman refuse deux réseaux sur le même subnet ; le subnet est dérivé du chemin absolu du projet (`cksum`), avec repli séquentiel en cas de collision rare |
| Conteneurs `gateway`/`workspace` | par (projet, client) | noms uniques, pas de conflit si plusieurs projets tournent en même temps |
| Images overlay (gateway/workspace de chaque client) | par (projet, client) | l'allowlist Squid d'un projet ne doit jamais écraser silencieusement le même tag pendant qu'un autre projet tourne encore dessus |
| Images `*-base` (gateway-base, workspace-base) | **globales** | aucun contenu spécifique à un projet — un seul tag partagé profite du cache de layers |
| Volume des paquets installés (`~/.local` pip, `~/.npm-global` npm) | par projet | ce sont de VRAIS paquets installés par le CLI IA, pas un simple cache : un paquet compromis installé dans un projet ne doit pas devenir importable depuis un autre |
| Volume de cache de téléchargement (`~/.cache`) | par projet | même raisonnement que le volume de paquets : le cache HTTP pip/npm est un vecteur d'installation (un artefact empoisonné déposé par un CLI compromis dans un projet serait réinstallé sans revalidation de hash par un autre). Coût assumé : chaque nouveau projet repart avec un cache vide |
| Volume d'état persistant du CLI (`~/.copilot` pour Copilot — session, jeton d'auth ; optionnel, absent pour un client qui n'en a pas besoin) | par projet | même raisonnement que le volume de paquets : un jeton d'auth compromis dans un projet ne doit pas être silencieusement réutilisable depuis un autre |

`./scripts/run.sh doctor` affiche le nom de projet détecté et le réseau qui lui correspond. Deux projets qui portent le même nom de dossier entreraient en collision de noms de ressources ; forcez un nom explicite avec `IA_PROJECT_NAME=mon-projet-2 ./scripts/run.sh up` dans ce cas.

**Vérifié dans ce sandbox** : deux projets factices, chacun avec sa propre copie de `ia-dev-containers`, lancés simultanément (`run.sh up` sur les deux) — réseaux et subnets distincts confirmés (`podman network inspect`), gateways des deux projets actifs en parallèle, workspace de chacun ne voyant que ses propres fichiers, suite de sécurité complète (14/14) rejouée avec succès dans ce contexte multi-projets.
