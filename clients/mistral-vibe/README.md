# Mistral Vibe CLI - Sandbox à deux conteneurs (gateway + workspace)

> **Environnement isolé pour développer avec Mistral Vibe CLI**

---

## 🎯 **Principe**

Ce sandbox exécute Mistral Vibe CLI dans un conteneur **`workspace`** qui n'a **aucune route réseau directe** vers l'extérieur — il ne peut joindre qu'un conteneur **`gateway`** séparé, qui seul possède un accès réseau réel et applique une allowlist de domaines via Squid.

Voir le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) pour le détail de l'architecture et pourquoi elle est construite ainsi (un seul conteneur ne peut pas garantir les deux propriétés à la fois : accès réseau réel pour le proxy *et* impossibilité de le contourner).

**Ce dossier `ia-dev-containers` est prévu pour être copié à la racine du projet à sandboxer** (`mon-projet/ia-dev-containers/`). `/workspace` dans le conteneur est alors un accès direct à la racine du projet (bind-mount), pas une copie ni un volume vide — le CLI IA travaille sur les vrais fichiers. Voir l'avertissement dans le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) pour les implications.

---

## 🚀 **Utilisation**

### **Prérequis**

- [Podman](https://podman.io/) installé (testé avec Podman 5.8.3, rootless, backend réseau `netavark`)
- macOS/Windows : voir [docs/macos.md](../../docs/macos.md) / [docs/windows.md](../../docs/windows.md) avant de continuer — expérimental, non vérifié sur matériel réel.

### **Démarrage**

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/mistral-vibe

./scripts/run.sh up      # construit les images, crée le réseau dédié à ce projet, démarre le gateway
./scripts/run.sh shell   # lance un shell interactif dans le workspace (= racine du projet)
```

Sous-commandes disponibles :

| Commande | Effet |
|---|---|
| `run.sh up` | build des images + création du réseau interne dédié à ce projet + démarrage du gateway |
| `run.sh shell [-- CMD...]` | démarre (ou réutilise) le gateway, puis un workspace interactif (ou exécute `CMD`) |
| `run.sh test` | démarre le workspace et exécute `security-tests.sh` |
| `run.sh down [--purge-network]` | arrête les conteneurs (et supprime le réseau si demandé) |
| `run.sh secrets` | affiche le statut des secrets attendus |
| `run.sh doctor` | diagnostic plateforme hôte + projet/réseau détecté pour cette copie |

Variables d'environnement :

| Variable | Valeurs | Effet |
|---|---|---|
| `GATEWAY_HARDENED` | `0` (défaut) / `1` | `1` active nftables + abandon de privilèges sur le gateway |
| `GATEWAY_ADDR_MODE` | `dns` (défaut) / `static` | `static` utilise l'IP fixe du gateway au lieu de la résolution DNS `gateway` |
| `IA_PROJECT_ROOT` | chemin | force la racine du projet (défaut : dossier parent de cette copie) |
| `IA_PROJECT_NAME` | texte | force le nom utilisé pour scoper les ressources Podman (défaut : nom du dossier `IA_PROJECT_ROOT`) — utile si deux projets partagent le même nom de dossier |

Exemple avec le gateway durci :
```bash
GATEWAY_HARDENED=1 ./scripts/run.sh up
GATEWAY_HARDENED=1 ./scripts/run.sh test
```

### **Avec VS Code**

1. Lancer `./scripts/run.sh up` **depuis un terminal, avant** d'ouvrir VS Code (le devcontainer n'orchestre que le `workspace`, pas le `gateway` ni le réseau ; `run.sh up` génère aussi `devcontainer.json`, à partir du squelette partagé `scripts/devcontainer-skeleton.json.template` + `scripts/lib.sh` — ne l'éditez pas directement, il est régénéré à chaque `up`).
2. Ouvrir `clients/mistral-vibe` dans VS Code, extension **Remote - Containers**, `F1` → *Reopen in Container*.

> ℹ️ `devcontainer.json` n'utilise pas `--secret` (un `runArg` statique casserait le démarrage si le secret n'existe pas encore). Pour les secrets sous VS Code : créez le `podman secret` au préalable dans un terminal (il persiste indépendamment du conteneur), ou utilisez `.env`.

---

## 🔧 **Installation de Mistral Vibe CLI**

Dans le workspace :
```bash
pip install --user mistral-vibe
pip install --user --upgrade mistral-vibe   # mise à jour
mistral-vibe --version
```

> Testé de bout en bout : `pip install --user requests` fonctionne à travers le gateway (résolution DNS explicite dans Squid, allowlist PyPI).

---

## 🔑 **Secrets (clé API Mistral, etc.)**

**Méthode recommandée : `podman secret`**
```bash
printf '%s' 'sk-...' | podman secret create mistral-vibe-mistral-api-key -
./scripts/run.sh secrets   # vérifie que c'est bien pris en compte
```

`run.sh` détecte automatiquement les secrets `podman` existants (voir `scripts/lib.sh` : `SECRETS`) et les injecte en variable d'environnement (`type=env`) dans le workspace. Gain **vérifié** par rapport à `.env`/`-e` : la valeur n'apparaît jamais dans `podman inspect` (testé : `-e`/`--env-file` l'affichent en clair, `podman secret` affiche `nom-du-secret=*******`). Ce n'est **pas** un chiffrement au repos (le driver par défaut `file` stocke en clair, comme un `.env` en `chmod 600`) et ça ne protège pas la valeur contre le CLI IA lui-même, qui doit la lire pour fonctionner — seulement contre son exposition accidentelle dans `podman inspect`, les logs, un partage d'écran ou un rapport de bug.

**Repli : `.env`** (si vous préférez, ou pour compléter un secret non couvert)
```bash
cp .env.example .env
chmod 600 .env
# éditer .env, renseigner MISTRAL_API_KEY
```
`run.sh` charge `.env` via `--env-file` s'il existe et si aucun `podman secret` du même nom n'est défini (le secret est prioritaire en cas de doublon). `.env` est ignoré par git, mais sa valeur reste visible en clair dans `podman inspect` — contrairement à `podman secret`.

---

## 📋 **Mesures de sécurité**

| Mesure | Composant | Détail |
|---|---|---|
| Aucune route directe vers l'extérieur | `workspace` | réseau Podman `--internal`, pas de route par défaut |
| Seul point d'accès réseau réel | `gateway` | double-attaché (réseau interne dédié au projet + `podman`) |
| Allowlist de domaines | `gateway` | ACL Squid `dstdomain`, voir `gateway/config/allowed-urls.txt` |
| Verrouillage egress du gateway lui-même | `gateway` (`GATEWAY_HARDENED=1`) | nftables : ports 80/443 uniquement, blocage RFC1918 + métadonnées cloud |
| Le gateway ne route jamais entre ses interfaces | `gateway` | chaîne `forward` nftables vide, `ip_forward=0` vérifié au démarrage |
| Non-root | `workspace` (UID 1000), `gateway` (nobody) | |
| Abandon définitif des privilèges | `gateway` (`GATEWAY_HARDENED=1`) | `su-exec nobody` après chargement des règles réseau, capacités effectives = 0 |
| Lecture seule | les deux conteneurs | `--read-only` + tmpfs |
| `pip install --user` sans sudo | `workspace` | |
| Auto-protection | `ia-dev-containers/` remonté en lecture seule sur lui-même dans `/workspace` (par défaut) | `run.sh doctor` pour le statut, `run.sh test` pour la vérification — voir l'avertissement dans le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) |
| Cohérence CLI / VS Code | Contrat d'isolation, proxy et `IA_CLIENT` générés depuis une source unique — `run.sh shell`/`test` et le devcontainer VS Code ne peuvent pas diverger | `scripts/common.sh`, voir le [README racine](../../README.md#-mesures-de-sécurité-implémentées) |
| Isolation entre projets | réseau, conteneurs, images overlay, `~/.local` | scopés par projet, voir [README racine](../../README.md#-isolation-entre-projets) |
| ⚠️ **Non couvert** | `/workspace` | bind-mount du projet réel, pas un volume vide — voir l'avertissement dans le [README racine](../../README.md#️-architecture--deux-conteneurs-gateway--workspace) |

### **URLs autorisées par défaut**

- **Mistral AI** : `api.mistral.ai`, `mistral.ai`
- **GitHub** : `github.com`, `api.github.com`, `raw.githubusercontent.com`, `camo.githubusercontent.com`, `user-images.githubusercontent.com`
- **PyPI** : `pypi.org`, `pypi.python.org`, `files.pythonhosted.org`
- **Hugging Face** : `huggingface.co`, `api.huggingface.co`, `cdn.huggingface.co`
- **CDN** : `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`

Pour ajouter un domaine : éditer `gateway/config/allowed-urls.txt`, puis `./scripts/run.sh down && ./scripts/run.sh up`.

> ⚠️ **Limite connue** : l'allowlist par domaine réduit le risque d'exfiltration sans l'éliminer (des domaines autorisés comme GitHub ou Hugging Face exposent des surfaces en écriture).
>
> ⚠️ **Contrainte assumée** : seuls les remotes git en **HTTPS** fonctionnent (le SSH, port 22, n'est pas relayé).

---

## 🧪 **Vérifier la sécurité**

```bash
./scripts/run.sh test
```

Ce que le script vérifie réellement (exécuté depuis le workspace, contre le vrai gateway — jamais localhost) :
1. Le workspace ne peut **pas** atteindre internet directement (`curl --noproxy '*' https://1.1.1.1` → *network unreachable*).
2. Le workspace **peut** atteindre un domaine autorisé via le gateway (`curl -x http://gateway:3128 https://pypi.org` → 200).
3. Le workspace **ne peut pas** atteindre un domaine non autorisé via le gateway (`curl -x http://gateway:3128 https://facebook.com` → 403).

Plus les vérifications habituelles : non-root, sudo bloqué, filesystem en lecture seule, `ia-dev-containers/` lisible mais protégé en écriture (auto-protection, voir le tableau ci-dessus), `~/.local` inscriptible, Python/pip disponibles.

Vérifications côté gateway (utilisateur effectif de Squid, `ip_forward`, capacités) :
```bash
# Nom de conteneur scopé par projet : mistral-vibe-<projet>-gateway (voir `run.sh doctor`)
podman exec $(podman ps --filter name=mistral-vibe- --filter name=-gateway --format '{{.Names}}') /gateway-checks.sh
```

---

## 🔄 **Mise à jour**

```bash
podman pull docker.io/library/alpine:3.24            # gateway-base
podman pull docker.io/library/debian:bookworm-slim   # workspace-base (partagé avec le client Copilot)
./scripts/run.sh down --purge-network
podman build --no-cache -t ia-dev-containers-gateway-base:latest ../../gateway-base
podman build --no-cache -t ia-dev-containers-workspace-base:latest ../../workspace-base
./scripts/run.sh up
```

> `gateway-base` et `workspace-base` sont partagés avec [le client Copilot](../copilot/README.md) : reconstruire l'un ou l'autre affecte les deux clients.

---

## ❓ **FAQ**

**Pourquoi deux conteneurs et pas un seul avec `--network=none` ?**
Parce que c'est impossible à faire fonctionner correctement : `--network=none` retire toute interface réseau (sauf loopback) du conteneur, donc un proxy qui tournerait dans ce même conteneur n'aurait aucun moyen de relayer quoi que ce soit vers l'extérieur. Sans `--network=none`, rien ne peut forcer le trafic à passer par le proxy (ça demanderait `NET_ADMIN`, incompatible avec `--cap-drop=ALL`). Deux conteneurs séparés résolvent ce dilemme.

**Pourquoi Podman et pas Docker ?**
Rootless par défaut, pas de daemon, compatible avec les images Docker.

**Comment tester le proxy manuellement ?**
```bash
./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com    # doit réussir
./scripts/run.sh shell -- curl --noproxy '*' https://google.com            # doit échouer (pas de route)
```

**Le conteneur ne démarre pas, que faire ?**
```bash
./scripts/run.sh doctor   # affiche le projet détecté et le nom du réseau attendu
podman ps -a --filter name=mistral-vibe-
podman logs <nom-du-conteneur>
```

**Puis-je sandboxer plusieurs projets en même temps ?**
Oui — copiez `ia-dev-containers` à la racine de chaque projet, lancez `run.sh up` dans chacun. Réseau, conteneurs, images overlay et volume de paquets installés (`~/.local`) sont automatiquement scopés par projet (voir [Isolation entre projets](../../README.md#-isolation-entre-projets) dans le README racine) ; les images `*-base` et le cache pip (`~/.cache`) restent partagés.

---

## 📜 **Licence**

MIT - Libre d'utiliser, modifier et distribuer.
