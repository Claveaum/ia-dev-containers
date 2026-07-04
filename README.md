# IA Dev Containers
> **Environnements de développement sécurisés pour clients IA CLI**

Ce projet fournit des **conteneurs Podman sécurisés** pour développer avec des clients IA CLI (Mistral Vibe, GitHub Copilot, etc.) **sans compromettre la sécurité de votre poste de travail**.

**Mode d'emploi** : copiez ce dossier (`ia-dev-containers/`) à la **racine du projet** que vous voulez sandboxer (`mon-projet/ia-dev-containers/`). Le workspace du conteneur est alors un accès direct à `mon-projet/` (bind-mount) : le CLI IA travaille sur les vrais fichiers du projet, pas sur une copie. Plusieurs projets (donc plusieurs copies) peuvent tourner **en parallèle** sur la même machine, chacun isolé du reste (réseau, images, volumes de paquets installés — détails dans [docs/architecture.md](docs/architecture.md)).

---

## 🎯 Objectifs principaux

- ✅ **Isolation totale** : le CLI IA ne peut **pas accéder** à votre système hôte
- ✅ **Accès réseau contrôlé** : seuls les domaines **nécessaires au développement** sont autorisés
- ✅ **Installation de dépendances sécurisée** : `pip install --user`, `npm install --prefix`, sans `sudo`
- ✅ **Protection contre l'exfiltration** : le CLI ne peut pas envoyer de données vers des serveurs non autorisés
- ✅ **Intégration VS Code** : utilisable comme Dev Container

---

## 🏗️ Architecture en bref

Le sandbox repose sur **deux conteneurs séparés**, jamais un seul :

- **`gateway`** : le seul conteneur avec un accès réseau réel. Fait tourner Squid, applique l'allowlist de domaines.
- **`workspace`** : exécute le CLI IA (non fiable par hypothèse). Attaché **uniquement** à un réseau Podman `--internal`, sans route par défaut vers l'extérieur.

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

Un seul conteneur ne peut pas offrir à la fois un vrai accès réseau pour le proxy *et* une garantie noyau que le workload ne peut pas le contourner — séparer les deux rôles résout ce dilemme. Un durcissement optionnel (`GATEWAY_HARDENED=1`) ajoute des règles nftables verrouillant l'egress du gateway lui-même. Détail complet (pourquoi cette séparation, les deux niveaux de durcissement, structure du dépôt, isolation entre projets) : [docs/architecture.md](docs/architecture.md).

> ⚠️ **`/workspace` est un accès direct au projet hôte, pas une copie isolée.** Le CLI IA lit et écrit les vrais fichiers du projet — un fichier qu'il y laisse (hook git, script de build, config CI) peut ensuite s'exécuter côté hôte. Revoyez les diffs comme pour toute contribution externe. Cas particulier : `ia-dev-containers/` étant lui-même dans ce bind-mount, il est protégé par défaut en lecture seule sur lui-même (**auto-protection**, visible via `run.sh doctor`) pour empêcher le CLI de modifier sa propre allowlist ou ses propres scripts — voir [docs/architecture.md](docs/architecture.md#workspace-est-un-accès-direct-au-projet-hôte-pas-une-copie-isolée) pour le mécanisme complet et l'option de relocalisation hors du projet.

---

## 🚀 Démarrage rapide (Mistral Vibe CLI)

**Prérequis hôte** : [Podman](https://podman.io/) et `python3` (requis par l'orchestrateur `scripts/orchestrator.py`, côté hôte uniquement — voir [🖥️ Plateformes hôte](#️-plateformes-hôte) plus bas).

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/mistral-vibe

./scripts/run.sh up      # construit les images, crée le réseau interne dédié à ce projet, démarre le gateway
./scripts/run.sh shell   # shell interactif dans le workspace — /workspace = racine de votre projet
./scripts/run.sh test    # suite de tests de sécurité
./scripts/run.sh down    # arrête tout (--purge-network pour aussi supprimer le réseau)
```

Une fois dans le workspace :
```bash
pip install --user mistral-vibe
mistral-vibe
```

Pour activer le durcissement du gateway : `GATEWAY_HARDENED=1 ./scripts/run.sh up`.

Toutes les sous-commandes (`exec`, `purge`, `logs`, `secrets`, `doctor`, ...) et variables d'environnement sont détaillées dans le [README Mistral Vibe](clients/mistral-vibe/README.md).

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

## 🖥️ Plateformes hôte

| Plateforme | Statut | Guide |
|---|---|---|
| Linux | ✅ **Testé** (Podman 5.8.3 rootless, netavark) | ce README |
| macOS | ⚠️ **Expérimental, non vérifié sur matériel réel** | [docs/macos.md](docs/macos.md) |
| Windows | ⚠️ **Expérimental, non vérifié sur matériel réel** (bug amont connu, voir [Dépannage](docs/troubleshooting.md)) | [docs/windows.md](docs/windows.md) |

Sur macOS/Windows, Podman passe par une VM Linux (`podman machine`) — l'architecture devrait s'y comporter à l'identique, mais ça n'a été vérifié que par analyse, pas par exécution réelle sur matériel réel. `./scripts/run.sh doctor` (dans chaque client) diagnostique la plateforme hôte et l'état de la VM le cas échéant.

---

## 🔒 Sécurité

Isolation réseau par topologie (pas par convention), allowlist de domaines côté gateway (Squid), `--cap-drop=ALL` + lecture seule + non-root sur les deux conteneurs, secrets via `podman secret` (jamais `-e CLE=valeur`), auto-protection de `ia-dev-containers/` en lecture seule sur lui-même, isolation des ressources Podman par projet.

Table complète des mesures, limites connues (ex. allowlist qui réduit l'exfiltration sans l'éliminer, comportement sous Podman rootful/SELinux) et bonnes pratiques d'exploitation : [docs/security.md](docs/security.md).

---

## 🛠 Personnalisation

Ajouter un nouveau client IA ne demande d'écrire que ce qui varie réellement (allowlist, Dockerfile, `lib.sh`) — toute l'orchestration (build, mounts, devcontainer, tests) est générique et partagée. Marche à suivre complète : [docs/adding-a-client.md](docs/adding-a-client.md).

---

## 🔧 Dépannage

Workspace qui ne démarre pas, gateway injoignable, domaine bloqué, bug Podman/nftables connu sous Windows, proxy corporate avec inspection TLS, mise à jour d'une copie déjà déployée : voir [docs/troubleshooting.md](docs/troubleshooting.md).

---

## 📋 Comparatif des solutions

| **Client** | **Langage** | **Statut** |
|-----------|-------------|-----------|
| Mistral Vibe | Python 3 | ✅ **Généré et testé** (Phase simple + durcie, `pip install` réel via le gateway) |
| GitHub Copilot | Node.js 22+ | ✅ **Généré et testé** (Phase simple + durcie, `npm install -g @github/copilot` réel via le gateway) ; session authentifiée non testée (nécessite un abonnement Copilot) |

---

## 📚 Documentation

- **[Mistral Vibe CLI](clients/mistral-vibe/README.md)** — solution complète, testée
- **[GitHub Copilot CLI](clients/copilot/README.md)** — solution complète, testée (mécanique du sandbox ; session authentifiée non testée)
- **[docs/architecture.md](docs/architecture.md)** — architecture détaillée, bind-mount, auto-protection, structure du projet, isolation entre projets
- **[docs/security.md](docs/security.md)** — mesures de sécurité complètes, limites connues, bonnes pratiques
- **[docs/adding-a-client.md](docs/adding-a-client.md)** — ajouter un nouveau client IA
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — dépannage et mise à jour d'une copie déployée
- **[docs/macos.md](docs/macos.md)** / **[docs/windows.md](docs/windows.md)** — guides plateforme (expérimentaux)

---

## 🤝 Contribuer

1. Forker le projet
2. Créer une branche (`git checkout -b feature/ma-fonctionnalité`)
3. Committer vos changements
4. Ouvrir une Pull Request

---

## 📜 Licence

MIT - Libre d'utiliser, modifier et distribuer.

---

## 📧 Support

1. Consultez les READMEs spécifiques à chaque client
2. Vérifiez les logs (`podman ps --filter name=-gateway`, puis `podman logs <nom>`)
3. Exécutez `./scripts/run.sh test` et `./scripts/run.sh doctor`
4. Ouvrez une issue dans le dépôt
