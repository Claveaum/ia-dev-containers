# GitHub Copilot CLI - Sandbox à deux conteneurs (gateway + workspace)

> **Environnement isolé pour développer avec GitHub Copilot CLI (`@github/copilot`)**

---

## 🎯 **Principe**

Même architecture que [Mistral Vibe](../mistral-vibe/README.md) : un conteneur **`workspace`** sans route réseau directe, qui ne peut joindre qu'un conteneur **`gateway`** séparé appliquant une allowlist de domaines via Squid. Voir le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) pour le détail de l'architecture.

Réseau interne dédié, scopé par (client, projet) — distinct de celui de mistral-vibe, et distinct entre deux projets différents — pour que plusieurs clients et plusieurs projets puissent tourner simultanément sans conflit de subnet Podman (voir [Isolation entre projets](../../README.md#-isolation-entre-projets) dans le README racine).

**Ce dossier `ia-dev-containers` est prévu pour être copié à la racine du projet à sandboxer** (`mon-projet/ia-dev-containers/`). `/workspace` dans le conteneur est alors un accès direct à la racine du projet (bind-mount), pas une copie ni un volume vide — le CLI IA travaille sur les vrais fichiers. Voir l'avertissement dans le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) pour les implications.

---

## ⚠️ **Ce qui est vérifié, et ce qui ne l'est pas**

Ce client a été validé pour les mêmes propriétés mécaniques que mistral-vibe : isolation réseau (aucune route directe), allowlist de domaines fonctionnelle (y compris le matching de sous-domaines `*.githubcopilot.com`), non-root, filesystem en lecture seule, `npm install -g` fonctionnel dans `~/.npm-global`. Le CLI `copilot` a aussi été vérifié capable de démarrer et d'initialiser son état (`~/.copilot`, volume dédié — voir plus bas) sans authentification réelle : sans ce volume, il quittait silencieusement (aucune sortie, code 1) dès le premier lancement, faute de pouvoir écrire sous `$HOME` en lecture seule.

**Vérifié sur matériel réel (macOS Apple Silicon)** : le binaire natif de `@github/copilot` (`@github/copilot-linuxmusl-arm64`) segfaute de façon reproductible sur Alpine (musl), y compris hors de tout durcissement du sandbox (cap-drop, read-only, userns retirés — même résultat) — bug upstream connu, non résolu ([github/copilot-cli#107](https://github.com/github/copilot-cli/issues/107)). `workspace-base` est passé sur Debian bookworm-slim (glibc) pour cette raison ; `copilot --version` a été confirmé fonctionnel après cette bascule.

**Non testé ici** : une session Copilot CLI authentifiée de bout en bout (nécessite un abonnement GitHub Copilot actif et des identifiants réels, indisponibles dans cet environnement de développement). Si un domaine nécessaire à l'authentification ou à l'usage réel manque à l'allowlist, ajoutez-le à `gateway/config/allowed-urls.txt` (voir la section Dépannage).

---

## 🚀 **Utilisation**

### **Prérequis**

- [Podman](https://podman.io/) installé (testé avec Podman 5.8.3, rootless, backend réseau `netavark`)
- `python3` installé (requis par `scripts/orchestrator.py`, voir [README racine](../../README.md#️-plateformes-hôte))
- macOS/Windows : voir [docs/macos.md](../../docs/macos.md) / [docs/windows.md](../../docs/windows.md) avant de continuer — expérimental, non vérifié sur matériel réel.

### **Démarrage**

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/copilot

./scripts/run.sh up      # construit les images, crée le réseau dédié à ce projet, démarre le gateway
./scripts/run.sh shell   # lance un shell interactif dans le workspace (= racine du projet)
```

Mêmes sous-commandes et variables d'environnement que mistral-vibe (`up|shell|test|down|secrets|doctor`, `GATEWAY_HARDENED`, `GATEWAY_ADDR_MODE`, `IA_PROJECT_ROOT`, `IA_PROJECT_NAME`) — voir le [README mistral-vibe](../mistral-vibe/README.md#-utilisation) pour le détail, identique ici.

### **Avec VS Code**

1. Lancer `./scripts/run.sh up` **depuis un terminal, avant** d'ouvrir VS Code (génère aussi `devcontainer.json`, à partir du squelette partagé `scripts/devcontainer-skeleton.json.template` + `scripts/lib.sh` — ne l'éditez pas directement, il est régénéré à chaque `up`).
2. Ouvrir `clients/copilot` dans VS Code, extension **Remote - Containers**, `F1` → *Reopen in Container*.

> ℹ️ `devcontainer.json` n'utilise pas `--secret` (voir [note équivalente côté mistral-vibe](../mistral-vibe/README.md#avec-vs-code)) : créez le `podman secret` au préalable dans un terminal, ou utilisez `.env`.

---

## 🔧 **Installation de GitHub Copilot CLI**

Dans le workspace :
```bash
npm install -g @github/copilot
copilot --version
```

> Node.js ≥ 22 est requis par `@github/copilot`. Ce Dockerfile copie le runtime Node officiel (`node:22-bookworm-slim`, glibc) plutôt que d'installer le paquet `nodejs` de Debian (absent/trop ancien dans les dépôts stables) — voir `clients/copilot/workspace/Dockerfile`. `workspace-base` (partagé avec mistral-vibe) est lui-même sur Debian bookworm-slim (glibc), pas Alpine : le binaire natif de `@github/copilot` segfaute de façon reproductible sur musl, indépendamment de tout durcissement du sandbox (bug upstream connu).

### **Authentification**

Par défaut, `@github/copilot` s'authentifie via device flow interactif (URL + code affichés dans le terminal, à valider sur `github.com/login/device` — déjà couvert par l'allowlist). Le token obtenu ne survit pas à l'arrêt du conteneur (`--rm`), il faudra se réauthentifier à chaque session sauf si vous le persistez vous-même (volume dédié à l'endroit où le CLI stocke ses credentials).

Alternative non interactive : un token d'accès personnel (PAT), **méthode recommandée : `podman secret`**
```bash
printf '%s' 'ghp_...' | podman secret create copilot-gh-token -
./scripts/run.sh secrets   # vérifie que c'est bien pris en compte
```
`run.sh` détecte automatiquement ce secret et l'injecte en variable d'environnement (`GH_TOKEN`) dans le workspace. Gain **vérifié** par rapport à `.env`/`-e` : la valeur n'apparaît jamais dans `podman inspect` (testé). Ce n'est pas un chiffrement au repos et ça ne protège pas la valeur contre le CLI IA lui-même — voir le détail dans le [README mistral-vibe](../mistral-vibe/README.md#-secrets-clé-api-mistral-etc), identique ici.

Repli : copier `.env.example` vers `.env` et renseigner `GH_TOKEN` — chargé via `--env-file` si aucun `podman secret` du même nom n'existe (le secret est prioritaire en cas de doublon).

---

## 📋 **Mesures de sécurité**

Identiques à mistral-vibe (voir son [README](../mistral-vibe/README.md#-mesures-de-sécurité)) : isolation réseau par topologie (pas par convention), allowlist Squid, verrouillage nftables optionnel du gateway (`GATEWAY_HARDENED=1`), non-root partout, lecture seule.

### **Domaines autorisés par défaut**

Dérivés de la [référence officielle GitHub](https://docs.github.com/en/copilot/reference/copilot-allowlist-reference) (sous-ensemble pertinent pour le CLI local) :

- **Auth & Copilot** : `github.com`, `api.github.com`
- **API Copilot** : `.githubcopilot.com` (avec point de tête — couvre tous les sous-domaines par plan/région)
- **Télémétrie** (désactivable, voir `allowed-urls.txt`) : `collector.github.com`, `copilot-telemetry.githubusercontent.com`, `default.exp-tas.com`
- **Proxy de suggestions** : `copilot-proxy.githubusercontent.com`, `origin-tracker.githubusercontent.com`
- **Contenu GitHub** : `raw.githubusercontent.com`, `camo.githubusercontent.com`, `objects.githubusercontent.com`, `codeload.github.com`
- **npm** : `registry.npmjs.org`, `npmjs.org`

> ⚠️ Cette liste couvre le CLI local, pas l'agent cloud de GitHub (« Copilot coding agent »), qui a son propre pare-feu bien plus large côté GitHub — non applicable ici.
>
> ⚠️ **Limite connue** : l'allowlist par domaine réduit le risque d'exfiltration sans l'éliminer.
>
> ⚠️ **Contrainte assumée** : seuls les remotes git en **HTTPS** fonctionnent (le SSH, port 22, n'est pas relayé).

Pour ajouter un domaine : éditer `gateway/config/allowed-urls.txt`, puis `./scripts/run.sh down && ./scripts/run.sh up`. Déjà léger : pas de `--purge-network` à ajouter (le réseau n'est pas concerné), et le rebuild est quasi instantané — seul l'overlay `gateway` (2 lignes de Dockerfile après le `COPY allowed-urls.txt`) est rejoué, le reste (`gateway-base`, `workspace-base`, l'overlay `workspace`) reste en cache de layers.

---

## 🧪 **Vérifier la sécurité**

```bash
./scripts/run.sh test
```

En plus des vérifications communes (non-root, sudo absent, lecture seule, résolution DNS externe bloquée, passerelle du bridge injoignable, `ia-dev-containers/` lisible mais protégé en écriture — auto-protection, voir le [tableau mistral-vibe](../mistral-vibe/README.md#-mesures-de-sécurité), Node/npm disponibles), ce test vérifie spécifiquement que `api.githubcopilot.com` passe par l'allowlist — un test discriminant pour le matching de sous-domaine Squid (`.githubcopilot.com` avec point de tête matche les sous-domaines, une entrée sans point ne matcherait que l'hôte exact).

```bash
# Nom de conteneur scopé par projet : copilot-<projet>-gateway (voir `run.sh doctor`)
podman exec $(podman ps --filter name=copilot- --filter name=-gateway --format '{{.Names}}') /gateway-checks.sh
```

---

## ❓ **FAQ**

Voir la [FAQ mistral-vibe](../mistral-vibe/README.md#-faq) (identique : pourquoi deux conteneurs, pourquoi Podman, comment tester le proxy manuellement, dépannage des conteneurs).

---

## 📜 **Licence**

MIT - Libre d'utiliser, modifier et distribuer.
