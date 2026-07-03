# IA Dev Containers
> **Environnements de développement sécurisés pour clients IA CLI**

Ce projet fournit des **conteneurs Podman sécurisés** pour développer avec des clients IA CLI (Mistral Vibe, GitHub Copilot, etc.) **sans compromettre la sécurité de votre poste de travail**.

**Mode d'emploi** : copiez ce dossier (`ia-dev-containers/`) à la **racine du projet** que vous voulez sandboxer (`mon-projet/ia-dev-containers/`). Le workspace du conteneur est alors un accès direct à `mon-projet/` (bind-mount) : le CLI IA travaille sur les vrais fichiers du projet, pas sur une copie. Plusieurs projets (donc plusieurs copies) peuvent tourner **en parallèle** sur la même machine, chacun isolé du reste (réseau, images, volumes de paquets installés — voir [Isolation entre projets](#-isolation-entre-projets)).

---

## 🎯 **Objectifs principaux**

- ✅ **Isolation totale** : le CLI IA ne peut **pas accéder** à votre système hôte
- ✅ **Accès réseau contrôlé** : seuls les domaines **nécessaires au développement** sont autorisés
- ✅ **Installation de dépendances sécurisée** : `pip install --user`, `npm install --prefix`, sans `sudo`
- ✅ **Protection contre l'exfiltration** : le CLI ne peut pas envoyer de données vers des serveurs non autorisés
- ✅ **Intégration VS Code** : utilisable comme Dev Container

---

## 🏗️ **Architecture : deux conteneurs (gateway + workspace)**

Le sandbox repose sur **deux conteneurs séparés**, jamais un seul :

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

> ⚠️ **`/workspace` est un accès direct au projet hôte, pas une copie isolée.** Le CLI IA lit et écrit les vrais fichiers du projet (bind-mount de la racine du projet, pas un volume Podman vide). C'est un choix assumé — le CLI doit pouvoir modifier le code, committer, lancer les outils du projet — mais ça élargit la surface par rapport à un volume vide : un fichier écrit par le CLI IA (hook git, script de build, `package.json`, config CI) peut ensuite s'exécuter **côté hôte** la prochaine fois que vous lancez une commande normale dans ce projet. L'isolation réseau/capacités/utilisateur du sandbox protège la machine hôte pendant que le CLI tourne ; elle ne protège pas rétroactivement le projet contre un fichier malveillant qu'il y aurait laissé. Revoyez les diffs comme vous le feriez pour toute contribution externe.
>
> ⚠️ **Cas particulier important : `ia-dev-containers/` lui-même est à l'intérieur du bind-mount.** Puisque cette copie est déposée à la racine du projet, elle fait partie de `/workspace`. **Auto-protection par défaut** : un second bind-mount, en lecture seule, est empilé sur `ia-dev-containers/` à l'intérieur du conteneur `workspace` — le CLI IA peut lire sa propre config sandbox (donc `git status`/`git add` lancés depuis le workspace restent normaux sur ces fichiers, qui suivent le dépôt du projet hôte), mais ne peut **plus** modifier `gateway/config/allowed-urls.txt` (élargir sa propre allowlist réseau), `scripts/run.sh`/`lib.sh`, ou les `Dockerfile` en écriture directe. Comme `build_images()` reconstruit l'overlay gateway/workspace à **chaque** `run.sh up`, c'était auparavant un vecteur direct : une allowlist modifiée aurait été reprise (et un script modifié réexécuté avec vos privilèges) dès le lancement suivant. `./scripts/run.sh doctor` affiche l'état de cette auto-protection (`active`, `désactivée`, ou `non applicable`) ; `./scripts/run.sh test` la vérifie (lecture OK, écriture bloquée). Cette protection est automatiquement désactivée dans deux cas où elle n'a pas de sens : la copie a été relocalisée hors de l'arborescence du projet (voir plus bas), ou `ia-dev-containers` est lui-même le projet sandboxé (dogfooding). Une échappatoire explicite existe pour le cas rare où le CLI IA doit modifier sa propre config sandbox depuis l'intérieur : `IA_SELF_MOUNT_RW=1 ./scripts/run.sh up`.
>
> Cette protection ne couvre que l'**écriture** sur `ia-dev-containers/` lui-même — le reste du projet hôte reste en bind-mount lecture-écriture normal (le CLI doit pouvoir modifier le code, committer, lancer les outils du projet), avec les mêmes implications qu'avant : un fichier écrit par le CLI IA ailleurs dans `/workspace` (hook git, script de build, `package.json`, config CI) peut ensuite s'exécuter côté hôte. Revoyez les diffs comme vous le feriez pour toute contribution externe. Même chose pour `clients/*/.env` s'il existe : la lecture directe par le CLI IA n'est pas changée par cette auto-protection (le mount lecture seule le laisse toujours lisible, pas une fuite nouvelle puisque le CLI a de toute façon la valeur via son environnement) — une raison de plus de préférer `podman secret` (dont le stockage vit hors du mount) pour tout secret que le CLI n'a pas besoin de *lire lui-même* en dehors de son usage normal.
>
> Si vous préférez éliminer entièrement `ia-dev-containers/` du bind-mount plutôt que de le protéger en lecture seule (par exemple pour empêcher toute lecture, pas seulement l'écriture), l'option de relocalisation reste disponible : déplacer physiquement `ia-dev-containers/` hors de l'arborescence du projet (ex. `~/.ia-sandboxes/mon-projet/ia-dev-containers/`) et lancer avec `IA_PROJECT_ROOT=/chemin/vers/mon-projet ./scripts/run.sh up` — **vérifié** : dans ce cas, `/workspace` ne contient plus `ia-dev-containers/` du tout, le CLI IA n'y a même pas accès en lecture, et l'auto-protection ci-dessus devient un no-op (rien à protéger).

---

## 📁 **Structure du projet**

```bash
mon-projet/                        # 🎯 Le projet que vous voulez sandboxer
├── ia-dev-containers/              # Cette copie, déposée à la racine
│   ├── gateway-base/               # 📦 Image générique du gateway (Squid, nftables)
│   │   ├── Dockerfile
│   │   ├── config/squid.conf       # ACL génériques, pas d'allowlist en dur
│   │   └── scripts/{entrypoint.sh, gateway.nft}
│   │
│   ├── workspace-base/             # 📦 Image générique du workspace (CLI IA)
│   │   ├── Dockerfile
│   │   └── scripts/entrypoint.sh
│   │
│   ├── scripts/                    # 🧩 Orchestrateur générique, partagé par tous les clients
│   │   ├── common.sh               # Gabarits de noms (image/réseau/volume) + auto-protection, côté hôte
│   │   ├── common-tests.sh         # Tests rapides sans Podman de common.sh (./scripts/common-tests.sh)
│   │   ├── orchestrator.sh         # up|shell|test|down|secrets|doctor — le seul point d'entrée : orchestrator_main()
│   │   └── security-tests-common.sh  # Batterie de tests générique, copiée dans l'image workspace
│   │
│   ├── clients/                    # 🎯 Adaptateurs par client IA (seulement ce qui varie)
│   │   ├── mistral-vibe/           # Adaptateur pour Mistral Vibe CLI (Python)
│   │   │   ├── gateway/            # Overlay : allowlist de domaines spécifique
│   │   │   │   ├── Dockerfile
│   │   │   │   ├── config/allowed-urls.txt
│   │   │   │   └── scripts/gateway-checks.sh
│   │   │   ├── workspace/          # Overlay : Python 3 + pip
│   │   │   │   └── Dockerfile
│   │   │   ├── scripts/
│   │   │   │   ├── lib.sh          # Adaptateur : CLIENT_NAME, volume de paquets, domaines testés, SECRETS, callback de test
│   │   │   │   ├── run.sh          # Point d'entrée mince : source lib.sh + common.sh + orchestrator.sh
│   │   │   │   └── security-tests.sh  # Point d'entrée mince (dans le conteneur) : source lib.sh + security-tests-common.sh
│   │   │   ├── .devcontainer/
│   │   │   │   └── devcontainer.json.template  # Généré en devcontainer.json par `run.sh up`
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

`gateway-base/` et `workspace-base/` sont partagés par les deux clients **et par tous les projets** (aucun contenu spécifique à un projet, un seul tag global profite du cache de layers). `gateway-base` reste sur Alpine 3.20 (Squid/nftables/abandon de privilèges déjà audités, aucune raison de le faire bouger). `workspace-base` est sur Alpine 3.21 (nécessaire pour Node.js ≥ 22, requis par Copilot CLI ; mistral-vibe en bénéficie aussi sans regression, revalidé après le bump).

Les images overlay (gateway/workspace de chaque client), le réseau `--internal` et les conteneurs sont en revanche scopés **par projet** (voir [Isolation entre projets](#-isolation-entre-projets)) : deux copies de `ia-dev-containers` dans deux projets différents ne se marchent jamais dessus, y compris lancées en même temps.

---

## 🚀 **Utilisation rapide (Mistral Vibe CLI)**

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/mistral-vibe

# Construit les images, crée le réseau interne dédié à ce projet, démarre le gateway
./scripts/run.sh up

# Lance un shell interactif dans le workspace — /workspace = racine de votre projet
./scripts/run.sh shell

# Lance la suite de tests de sécurité
./scripts/run.sh test

# Arrête tout (ajoutez --purge-network pour aussi supprimer le réseau)
./scripts/run.sh down
```

Une fois dans le workspace :
```bash
pip install --user mistral-vibe
mistral-vibe
```

Pour activer le durcissement du gateway (nftables + abandon de privilèges) :
```bash
GATEWAY_HARDENED=1 ./scripts/run.sh up
```

### GitHub Copilot CLI

Même principe, dans `clients/copilot/` :
```bash
cd ia-dev-containers/clients/copilot
./scripts/run.sh up
./scripts/run.sh shell
```
```bash
npm install -g @github/copilot
copilot
```
Voir le [README Copilot](clients/copilot/README.md) pour l'authentification et les limites de validation (une session authentifiée réelle n'a pas pu être testée sans abonnement Copilot).

---

## 🖥️ **Plateformes hôte**

| Plateforme | Statut | Guide |
|---|---|---|
| Linux | ✅ **Testé** (Podman 5.8.3 rootless, netavark) | ce README |
| macOS | ⚠️ **Expérimental, non vérifié sur matériel réel** | [docs/macos.md](docs/macos.md) |
| Windows | ⚠️ **Expérimental, non vérifié sur matériel réel** (bug amont connu, voir [Dépannage](#-dépannage)) | [docs/windows.md](docs/windows.md) |

Sur macOS/Windows, Podman ne tourne jamais nativement : il passe par une VM Linux (`podman machine`). L'architecture (isolation réseau par topologie, allowlist Squid) devrait s'y comporter à l'identique — mais ça n'a été vérifié que par analyse de l'architecture de `podman machine`, pas par exécution réelle. Tant que ce n'est pas fait, ces deux plateformes restent étiquetées expérimentales, dans le même esprit que la limite déjà documentée pour le client Copilot ("session authentifiée non testée") : ne rien affirmer de vérifié qui ne l'est pas.

`./scripts/run.sh doctor` (dans chaque client) diagnostique la plateforme hôte et l'état de la VM `podman machine` le cas échéant.

---

## 🔀 **Isolation entre projets**

Chaque copie de `ia-dev-containers` déduit son **nom de projet** (`PROJECT_NAME`) du nom du dossier qui la contient, et l'utilise pour scoper toutes les ressources Podman qu'elle crée — pas de registre central, pas de coordination requise entre projets :

| Ressource | Scope | Pourquoi |
|---|---|---|
| Réseau `--internal` (subnet `/24` dans `10.89.0.0/16`) | par (projet, client) | Podman refuse deux réseaux sur le même subnet ; le subnet est dérivé du chemin absolu du projet (`cksum`), avec repli séquentiel en cas de collision rare |
| Conteneurs `gateway`/`workspace` | par (projet, client) | noms uniques, pas de conflit si plusieurs projets tournent en même temps |
| Images overlay (gateway/workspace de chaque client) | par (projet, client) | l'allowlist Squid d'un projet ne doit jamais écraser silencieusement le même tag pendant qu'un autre projet tourne encore dessus |
| Images `*-base` (gateway-base, workspace-base) | **globales** | aucun contenu spécifique à un projet — un seul tag partagé profite du cache de layers |
| Volume des paquets installés (`~/.local` pip, `~/.npm-global` npm) | par projet | ce sont de VRAIS paquets installés par le CLI IA, pas un simple cache : un paquet compromis installé dans un projet ne doit pas devenir importable depuis un autre |
| Volume de cache de téléchargement (`~/.cache`) | **partagé** | rien d'exécutable "installé", juste des fichiers déjà téléchargés — partagé pour éviter de retélécharger pour chaque projet |

`./scripts/run.sh doctor` affiche le nom de projet détecté et le réseau qui lui correspond. Deux projets qui portent le même nom de dossier entreraient en collision de noms de ressources ; forcez un nom explicite avec `IA_PROJECT_NAME=mon-projet-2 ./scripts/run.sh up` dans ce cas.

**Vérifié dans ce sandbox** : deux projets factices, chacun avec sa propre copie de `ia-dev-containers`, lancés simultanément (`run.sh up` sur les deux) — réseaux et subnets distincts confirmés (`podman network inspect`), gateways des deux projets actifs en parallèle, workspace de chacun ne voyant que ses propres fichiers, suite de sécurité complète (12/12) rejouée avec succès dans ce contexte multi-projets.

---

## 🔒 **Mesures de sécurité implémentées**

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
| **Installation de dépendances** | `pip install --user` sans sudo | `workspace` |
| **Secrets** | `podman secret` (type=env), repli `--env-file .env` | `run.sh secrets` pour le statut ; jamais `-e CLE=valeur` |
| **Audit** | Tests automatiques exécutés contre le vrai gateway | `run.sh test` / `security-tests.sh` |
| **Isolation projet** | Réseau/conteneurs/images overlay/paquets installés scopés par projet | voir [Isolation entre projets](#-isolation-entre-projets) |
| **Auto-protection** | `ia-dev-containers/` remonté en lecture seule sur lui-même dans `/workspace` (par défaut) | `run.sh doctor` pour le statut, `run.sh test` pour la vérification ; voir l'avertissement dans [Architecture](#️-architecture--deux-conteneurs-gateway--workspace) |
| ⚠️ **Non couvert** | `/workspace` = bind-mount du projet réel, pas un volume vide (au-delà de `ia-dev-containers/` lui-même, protégé ci-dessus) | voir l'avertissement dans [Architecture](#️-architecture--deux-conteneurs-gateway--workspace) |
| ⚠️ **Affaibli sous SELinux** (Fedora/RHEL) | `workspace` tourne avec `--security-opt=label=disable` (confinement SELinux désactivé pour ce conteneur) | nécessaire pour que le bind-mount `/workspace` soit accessible sans relabeler les fichiers réels du projet sur disque (l'alternative `:Z` le ferait, effet de bord permanent hors du sandbox) ; no-op sur les hôtes sans SELinux (macOS, Windows, la plupart des distributions Linux hors Fedora/RHEL) |

---

## 🌐 **URLs autorisées par défaut (Mistral Vibe)**

*(Pour Copilot, voir [clients/copilot/README.md](clients/copilot/README.md#-domaines-autorisés-par-défaut).)*

- **Mistral AI** : `api.mistral.ai`, `mistral.ai`
- **GitHub** : `github.com`, `api.github.com`, `raw.githubusercontent.com`, `camo.githubusercontent.com`, `user-images.githubusercontent.com`
- **PyPI** : `pypi.org`, `pypi.python.org`, `files.pythonhosted.org`
- **Hugging Face** : `huggingface.co`, `api.huggingface.co`, `cdn.huggingface.co`
- **CDN** : `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`

> ⚠️ **Pour ajouter un domaine** : modifiez `clients/mistral-vibe/gateway/config/allowed-urls.txt` puis relancez `./scripts/run.sh down && ./scripts/run.sh up`.

> ⚠️ **Limite connue** : l'allowlist par domaine *réduit* le risque d'exfiltration, elle ne l'élimine pas. Des domaines autorisés comme `github.com` ou `huggingface.co` exposent des surfaces en écriture (gists, issues, upload de modèles) qui restent un vecteur résiduel.

> ⚠️ **Contrainte assumée** : seuls les remotes git en **HTTPS** fonctionnent. Le SSH (port 22) n'est pas relayé par le gateway.

---

## 📋 **Comparatif des solutions**

| **Client** | **Langage** | **Statut** |
|-----------|-------------|-----------|
| Mistral Vibe | Python 3 | ✅ **Généré et testé** (Phase simple + durcie, `pip install` réel via le gateway) |
| GitHub Copilot | Node.js 22+ | ✅ **Généré et testé** (Phase simple + durcie, `npm install -g @github/copilot` réel via le gateway) ; session authentifiée non testée (nécessite un abonnement Copilot) |

---

## 🛠 **Personnalisation**

### Ajouter un nouveau client IA

L'orchestration (up/shell/test/down/secrets/doctor, construction des images, mounts, rendu du devcontainer, batterie de tests) est générique et vit dans `scripts/orchestrator.sh` + `scripts/security-tests-common.sh`, partagés par tous les clients. Un nouveau client n'a besoin d'écrire que ce qui varie réellement pour lui :

1. Créer `clients/<nom-du-client>/gateway/` avec un `Dockerfile` (`FROM ia-dev-containers-gateway-base:latest`) + `config/allowed-urls.txt`.
2. Créer `clients/<nom-du-client>/workspace/` avec un `Dockerfile` (`FROM ia-dev-containers-workspace-base:latest`), qui doit se terminer par `USER devuser` (tout ce qui précède, comme `apk add`, a besoin de root). N'installez jamais le CLI IA lui-même au build (comme pip/npm au runtime pour les clients existants) : `HTTP_PROXY` ne pointe vers un `gateway` joignable qu'au runtime, pas au moment du build. Le Dockerfile doit aussi `COPY` `security-tests.sh`, `security-tests-common.sh` et `lib.sh` (voir `clients/mistral-vibe/workspace/Dockerfile` pour les chemins exacts — le contexte de build est la racine du dépôt, pas `clients/<nom-du-client>/`).
3. Créer `clients/<nom-du-client>/scripts/lib.sh` — l'adaptateur, en copiant `clients/mistral-vibe/scripts/lib.sh` comme modèle. Il déclare uniquement : `CLIENT_NAME`, `PKG_VOLUME_TARGET` (chemin du volume de paquets, ex. `/home/devuser/.local`), `PKG_VOLUME_PLACEHOLDER` (jeton du template devcontainer), `PKG_INSTALL_LABEL`, `TEST_DOMAIN_PRIMARY`/`TEST_DOMAIN_SECONDARY`, `SECRETS`, et la fonction `client_package_manager_tests()` (vérifications propres au gestionnaire de paquets). Tout le reste (noms de ressources Podman, allocation de subnet dans `10.89.0.0/16` via `ensure_network_and_ip`) en découle automatiquement depuis `scripts/common.sh` — pas d'attribution manuelle de `/24` ni de nom de ressource nécessaire.
4. Créer `clients/<nom-du-client>/scripts/run.sh` et `clients/<nom-du-client>/scripts/security-tests.sh` — copier ceux de `clients/mistral-vibe/scripts/` tels quels (ils ne contiennent plus rien de spécifique à un client, juste le câblage `source lib.sh` + délégation).
5. `./scripts/run.sh up` puis `./scripts/run.sh test` pour construire et valider réellement (pas seulement lire le code).

---

## 🔧 **Dépannage**

### Le workspace ne démarre pas / le réseau n'existe pas
Le workspace ne peut s'attacher qu'à un réseau `--internal` déjà créé (nom scopé par projet, ex. `ia-gw-internal-mistral-vibe-mon-projet` — voir `./scripts/run.sh doctor`). Lancez toujours `./scripts/run.sh up` (qui crée le réseau et démarre le gateway) avant `./scripts/run.sh shell`.

### Le gateway ne répond pas
```bash
# Nom de conteneur scopé par projet : <client>-<projet>-gateway (voir `run.sh doctor`)
podman ps --filter name=-gateway
podman logs <nom-du-conteneur-gateway>
podman exec <nom-du-conteneur-gateway> /gateway-checks.sh   # utilisateur squid, ip_forward, capacités
```

### Un domaine nécessaire est bloqué
Ajoutez-le à `clients/mistral-vibe/gateway/config/allowed-urls.txt`, puis reconstruisez (`./scripts/run.sh down && ./scripts/run.sh up`).

### Vérifier le proxy manuellement
```bash
./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com   # doit réussir
./scripts/run.sh shell -- curl --noproxy '*' https://1.1.1.1               # doit échouer (network unreachable)
```

### Windows (podman machine, provider `wsl`) : `podman network create --internal` échoue avec une erreur nftables

**Symptôme** : `./scripts/run.sh up` échoue à la création du réseau avec un message du type `nftables error: nft did not return successfully while applying ruleset` ou `Could not process rule: No such file or directory`.

**Cause** : bug amont connu, pas spécifique à ce projet — [containers/podman#25201](https://github.com/containers/podman/issues/25201) (ouvert le 2025-02-03, encore ouvert au moment de cette recherche, 2026-07). Le driver de pare-feu par défaut de `netavark` (`nftables`) est cassé dans une VM `podman machine` provider `wsl` sous Windows. C'est le pare-feu **interne** de Podman/netavark (utilisé pour implémenter `--internal`) qui est en cause — pas les règles nftables que notre propre `gateway` charge en Phase durcie (`GATEWAY_HARDENED=1`) via `nft -f`, qui s'exécutent dans un conteneur Linux classique et sont un mécanisme totalement indépendant portant juste le même nom.

**Contournement documenté en amont** : forcer `netavark` sur `iptables`. Dans la VM (`podman machine ssh`), créez/éditez `~/.config/containers/containers.conf` :
```toml
[network]
firewall_driver = "iptables"
```
puis `podman machine stop && podman machine start`.

**Alternative recommandée** : installer Podman directement dans une distribution WSL2 (`apt install podman` sous Ubuntu-on-WSL2), sans passer par `podman machine` — WSL2 fournit déjà un vrai noyau Linux, ce qui rend ce chemin équivalent à Linux natif et contourne ce bug de provider. Voir [docs/windows.md](docs/windows.md).

**Statut** : contournement rapporté par l'upstream Podman ; **non vérifié sur matériel Windows réel** dans le cadre de ce projet (voir [🖥️ Plateformes hôte](#️-plateformes-hôte) plus haut).

---

### Réseau d'entreprise avec inspection TLS (proxy corporate)

**Symptôme** : `podman build`/`podman pull` échouent avec une erreur de certificat, ou `apk add`/`pip install`/`npm install`/`git clone https://...` échouent dans le conteneur `workspace` avec une erreur TLS (`certificate verify failed`, `SSL certificate problem`), alors que `./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com` (voir plus haut) échoue aussi.

**Cause** : un équipement réseau d'entreprise intercepte le TLS sortant (port 443) et présente un certificat signé par une CA interne à la place du vrai certificat du serveur. Squid (`gateway`) ne fait que relayer le `CONNECT` sans déchiffrer (pas de `ssl-bump` dans `gateway-base/config/squid.conf`) : c'est donc le magasin de confiance **à l'intérieur** du conteneur `workspace` (où le TLS se termine réellement, côté `git`/`curl`/`pip`/`npm`) qui doit connaître la CA d'entreprise — pas seulement celui de l'hôte.

**Résolution en deux temps** :

1. **Hôte / VM `podman machine`** (prérequis — sinon `podman build`/`pull` échouent avant même d'atteindre un Dockerfile de ce projet) :
   - Linux natif : `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract` (Fedora/RHEL), ou `/usr/local/share/ca-certificates/` + `update-ca-certificates` (Debian/Ubuntu).
   - macOS/Windows (`podman machine`) : la CA doit être installée **dans la VM**, pas sur l'hôte — `podman machine ssh`, puis même procédure que Linux natif ci-dessus. ⚠️ Non persistant : `podman machine rm`/`init` recrée une VM vierge, il faut la réinstaller après. Voir [docs/macos.md](docs/macos.md) / [docs/windows.md](docs/windows.md).

2. **Images du projet** : déposez le certificat de la CA d'entreprise (format PEM, extension `.crt`) dans `gateway-base/certs/` **et** `workspace-base/certs/` (dossiers vides par défaut, ignorés par git — voir `.gitignore`), puis forcez un rebuild sans cache (`build_images()` dans `clients/*/scripts/run.sh` ne reconstruit pas si le tag existe déjà) :
   ```bash
   podman build --no-cache -t ia-dev-containers-gateway-base:latest   gateway-base/
   podman build --no-cache -t ia-dev-containers-workspace-base:latest workspace-base/
   ```
   Vérification : `podman run --rm --user 1000:1000 ia-dev-containers-workspace-base:latest grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt` doit afficher un compte supérieur à celui obtenu sans le fichier déposé.

**Cas non couvert** : si le réseau exige en plus un **proxy HTTP(S) explicite obligatoire** pour toute sortie (le gateway ne peut pas joindre internet directement, même avec la CA en place), il faudrait chaîner Squid vers ce proxy amont (`cache_peer` dans `gateway-base/config/squid.conf`) — non implémenté ici, à traiter séparément si besoin confirmé.

**Registre privé/auto-signé** (non applicable aujourd'hui — le projet ne pull que depuis Docker Hub public) : Podman a son propre mécanisme, indépendant de ce qui précède — `/etc/containers/certs.d/<host[:port]>/ca.crt` (rootful) ou `~/.config/containers/certs.d/<host[:port]>/ca.crt` (rootless).

---

## 🎓 **Bonnes pratiques**

1. **Secrets** : `podman secret create <nom> -` plutôt que `.env` (`.env` reste un repli valide) — le gain vérifié est que la valeur n'apparaît jamais dans `podman inspect`, ce n'est pas un chiffrement au repos. Jamais de `-e CLE=valeur` sur la ligne de commande. `./scripts/run.sh secrets` affiche le statut.
2. **Mettez à jour régulièrement** les images de base (`podman build --no-cache`). Toute modification de `gateway-base/certs/` ou `workspace-base/certs/` (CA d'entreprise, voir [Dépannage](#réseau-dentreprise-avec-inspection-tls-proxy-corporate)) nécessite le même rebuild forcé.
3. **Ne contournez jamais le gateway** : c'est la seule protection contre l'exfiltration. Pour un nouveau besoin réseau, ajoutez le domaine à l'allowlist plutôt que de désactiver le filtrage.
4. **Utilisez `GATEWAY_HARDENED=1`** dès que possible : la Phase durcie apporte une défense en profondeur (nftables) au cas où l'allowlist applicative serait un jour contournée.

---

## 📚 **Documentation par client**

- **[Mistral Vibe CLI](clients/mistral-vibe/README.md)** — solution complète, testée
- **[GitHub Copilot CLI](clients/copilot/README.md)** — solution complète, testée (mécanique du sandbox ; session authentifiée non testée)

---

## 🤝 **Contribuer**

1. Forker le projet
2. Créer une branche (`git checkout -b feature/ma-fonctionnalité`)
3. Committer vos changements
4. Ouvrir une Pull Request

---

## 📜 **Licence**

MIT - Libre d'utiliser, modifier et distribuer.

---

## 📧 **Support**

1. Consultez les READMEs spécifiques à chaque client
2. Vérifiez les logs (`podman ps --filter name=-gateway`, puis `podman logs <nom>`)
3. Exécutez `./scripts/run.sh test` et `./scripts/run.sh doctor`
4. Ouvrez une issue dans le dépôt
