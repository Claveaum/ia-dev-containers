# IA Dev Containers
> **Environnements de développement sécurisés pour clients IA CLI**

Ce projet fournit des **conteneurs Podman sécurisés** pour développer avec des clients IA CLI (Mistral Vibe, GitHub Copilot, etc.) **sans compromettre la sécurité de votre poste de travail**.

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
                          │ réseau "ia-gw-internal" (--internal, sans route sortante)
                    ┌─────▼─────┐
                    │ workspace │  CLI IA, cap-drop=ALL, read-only, non-root
                    └───────────┘
```

**Pourquoi cette séparation ?** Un seul conteneur ne peut pas offrir à la fois un vrai accès réseau pour le proxy *et* une garantie noyau que le workload ne peut pas le contourner (`--network=none` empêche les deux à la fois ; sans lui, `HTTP_PROXY` n'est qu'une convention qu'un process hostile peut ignorer). Séparer les deux rôles dans deux conteneurs résout ce dilemme : le `workspace` n'a physiquement aucune interface vers l'extérieur, quel que soit le comportement du CLI IA qu'il exécute.

Cette architecture est **construite et testée réellement** (Podman 5.8.3, réseau `--internal`, résolution DNS entre conteneurs via aardvark-dns) — pas seulement documentée sur le papier. Deux niveaux sont disponibles pour le gateway :

- **Phase simple** (`GATEWAY_HARDENED=0`, par défaut) : le gateway tourne directement en utilisateur `nobody`, sans capacité particulière.
- **Phase durcie** (`GATEWAY_HARDENED=1`) : le gateway démarre root-in-userns, charge des règles **nftables** verrouillant sa propre sortie (ports 80/443 uniquement, blocage des plages RFC1918 et de l'IP de métadonnées cloud `169.254.169.254`), vérifie que `net.ipv4.ip_forward=0`, puis abandonne définitivement ses privilèges vers `nobody` avant de lancer Squid.

---

## 📁 **Structure du projet**

```bash
ia-dev-containers/
├── gateway-base/                  # 📦 Image générique du gateway (Squid, nftables)
│   ├── Dockerfile
│   ├── config/squid.conf          # ACL génériques, pas d'allowlist en dur
│   └── scripts/{entrypoint.sh, gateway.nft}
│
├── workspace-base/                # 📦 Image générique du workspace (CLI IA)
│   ├── Dockerfile
│   └── scripts/entrypoint.sh
│
├── clients/                       # 🎯 Solutions par client IA
│   └── mistral-vibe/              # Solution pour Mistral Vibe CLI
│       ├── gateway/               # Overlay : allowlist de domaines spécifique
│       │   ├── Dockerfile
│       │   ├── config/allowed-urls.txt
│       │   └── scripts/gateway-checks.sh
│       ├── workspace/             # Overlay : Python 3 + pip
│       │   └── Dockerfile
│       ├── scripts/
│       │   ├── lib.sh             # Constantes partagées (réseau, images, noms)
│       │   ├── run.sh             # Orchestration : up|shell|test|down
│       │   └── security-tests.sh  # Suite de vérification (exécutée dans le workspace)
│       ├── .devcontainer/
│       │   └── devcontainer.json  # Configuration VS Code (workspace uniquement)
│       ├── .env.example           # Modèle pour les secrets (MISTRAL_API_KEY, ...)
│       └── README.md
│
└── .gitignore                     # Ignore les .env réels
```

`clients/copilot/` n'existe pas encore ; `gateway-base/` et `workspace-base/` sont conçus pour être réutilisés tels quels par un futur client Copilot.

---

## 🚀 **Utilisation rapide (Mistral Vibe CLI)**

```bash
cd ia-dev-containers/clients/mistral-vibe

# Construit les images, crée le réseau interne, démarre le gateway
./scripts/run.sh up

# Lance un shell interactif dans le workspace
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
| **Secrets** | `--env-file .env` (jamais `-e CLE=valeur`) | voir `.env.example` |
| **Audit** | Tests automatiques exécutés contre le vrai gateway | `run.sh test` / `security-tests.sh` |

---

## 🌐 **URLs autorisées par défaut (Mistral Vibe)**

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
| Mistral Vibe | Python 3 | ✅ **Généré et testé** (Phase simple + durcie) |
| GitHub Copilot | Node.js | ⏳ À générer |

---

## 🛠 **Personnalisation**

### Ajouter un nouveau client IA

1. Créer `clients/<nom-du-client>/gateway/` avec un `Dockerfile` (`FROM ia-dev-containers-gateway-base:latest`) + `config/allowed-urls.txt`.
2. Créer `clients/<nom-du-client>/workspace/` avec un `Dockerfile` (`FROM ia-dev-containers-workspace-base:latest`), qui doit se terminer par `USER devuser` (tout ce qui précède, comme `apk add`, a besoin de root).
3. Copier et adapter `clients/mistral-vibe/scripts/{lib.sh,run.sh,security-tests.sh}`.
4. `./scripts/run.sh up` pour construire et valider.

---

## 🔧 **Dépannage**

### Le workspace ne démarre pas / le réseau n'existe pas
Le workspace ne peut s'attacher qu'à un réseau `ia-gw-internal` déjà créé. Lancez toujours `./scripts/run.sh up` (qui crée le réseau et démarre le gateway) avant `./scripts/run.sh shell`.

### Le gateway ne répond pas
```bash
podman logs mistral-vibe-gateway
podman exec mistral-vibe-gateway /gateway-checks.sh   # utilisateur squid, ip_forward, capacités
```

### Un domaine nécessaire est bloqué
Ajoutez-le à `clients/mistral-vibe/gateway/config/allowed-urls.txt`, puis reconstruisez (`./scripts/run.sh down && ./scripts/run.sh up`).

### Vérifier le proxy manuellement
```bash
./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com   # doit réussir
./scripts/run.sh shell -- curl --noproxy '*' https://1.1.1.1               # doit échouer (network unreachable)
```

---

## 🎓 **Bonnes pratiques**

1. **Secrets** : copiez `clients/mistral-vibe/.env.example` vers `.env` (ignoré par git), jamais de `-e CLE=valeur` sur la ligne de commande.
2. **Mettez à jour régulièrement** les images de base (`podman build --no-cache`).
3. **Ne contournez jamais le gateway** : c'est la seule protection contre l'exfiltration. Pour un nouveau besoin réseau, ajoutez le domaine à l'allowlist plutôt que de désactiver le filtrage.
4. **Utilisez `GATEWAY_HARDENED=1`** dès que possible : la Phase durcie apporte une défense en profondeur (nftables) au cas où l'allowlist applicative serait un jour contournée.

---

## 📚 **Documentation par client**

- **[Mistral Vibe CLI](clients/mistral-vibe/README.md)** — solution complète, testée
- GitHub Copilot CLI — à générer

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
2. Vérifiez les logs (`podman logs mistral-vibe-gateway`, `podman logs mistral-vibe-workspace`)
3. Exécutez `./scripts/run.sh test`
4. Ouvrez une issue dans le dépôt
