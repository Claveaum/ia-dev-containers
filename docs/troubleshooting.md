# Dépannage

## Le workspace ne démarre pas / le réseau n'existe pas

Le workspace ne peut s'attacher qu'à un réseau `--internal` déjà créé (nom scopé par projet, ex. `ia-gw-internal-mistral-vibe-mon-projet` — voir `./scripts/run.sh doctor`). Lancez toujours `./scripts/run.sh up` (qui crée le réseau et démarre le gateway) avant `./scripts/run.sh shell`.

## Le gateway ne répond pas

```bash
# Nom de conteneur scopé par projet : <client>-<projet>-gateway (voir `run.sh doctor`)
podman ps --filter name=-gateway
podman logs <nom-du-conteneur-gateway>
podman exec <nom-du-conteneur-gateway> /gateway-checks.sh   # utilisateur squid, ip_forward, capacités
```

## Un domaine nécessaire est bloqué

Ajoutez-le à `clients/<client>/gateway/config/allowed-urls.txt`, puis reconstruisez (`./scripts/run.sh down && ./scripts/run.sh up`).

## Vérifier le proxy manuellement

```bash
./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com   # doit réussir
./scripts/run.sh shell -- curl --noproxy '*' https://1.1.1.1               # doit échouer (network unreachable)
```

## Windows (podman machine, provider `wsl`) : `podman network create --internal` échoue avec une erreur nftables

**Symptôme** : `./scripts/run.sh up` échoue à la création du réseau avec un message du type `nftables error: nft did not return successfully while applying ruleset` ou `Could not process rule: No such file or directory`.

**Cause** : bug amont connu, pas spécifique à ce projet — [containers/podman#25201](https://github.com/containers/podman/issues/25201) (ouvert le 2025-02-03, encore ouvert au moment de cette recherche, 2026-07). Le driver de pare-feu par défaut de `netavark` (`nftables`) est cassé dans une VM `podman machine` provider `wsl` sous Windows. C'est le pare-feu **interne** de Podman/netavark (utilisé pour implémenter `--internal`) qui est en cause — pas les règles nftables que notre propre `gateway` charge en Phase durcie (`GATEWAY_HARDENED=1`) via `nft -f`, qui s'exécutent dans un conteneur Linux classique et sont un mécanisme totalement indépendant portant juste le même nom.

**Contournement documenté en amont** : forcer `netavark` sur `iptables`. Dans la VM (`podman machine ssh`), créez/éditez `~/.config/containers/containers.conf` :
```toml
[network]
firewall_driver = "iptables"
```
puis `podman machine stop && podman machine start`.

**Alternative recommandée** : installer Podman directement dans une distribution WSL2 (`apt install podman` sous Ubuntu-on-WSL2), sans passer par `podman machine` — WSL2 fournit déjà un vrai noyau Linux, ce qui rend ce chemin équivalent à Linux natif et contourne ce bug de provider. Voir [docs/windows.md](windows.md).

**Statut** : contournement rapporté par l'upstream Podman ; **non vérifié sur matériel Windows réel** dans le cadre de ce projet (voir le [tableau Plateformes hôte](../README.md#️-plateformes-hôte) du README).

---

## Réseau d'entreprise avec inspection TLS (proxy corporate)

**Symptôme** : `podman build`/`podman pull` échouent avec une erreur de certificat, ou `apt-get install`/`pip install`/`npm install`/`git clone https://...` échouent dans le conteneur `workspace` avec une erreur TLS (`certificate verify failed`, `SSL certificate problem`), alors que `./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com` (voir plus haut) échoue aussi.

**Cause** : un équipement réseau d'entreprise intercepte le TLS sortant (port 443) et présente un certificat signé par une CA interne à la place du vrai certificat du serveur. Squid (`gateway`) ne fait que relayer le `CONNECT` sans déchiffrer (pas de `ssl-bump` dans `gateway-base/config/squid.conf`) : c'est donc le magasin de confiance **à l'intérieur** du conteneur `workspace` (où le TLS se termine réellement, côté `git`/`curl`/`pip`/`npm`) qui doit connaître la CA d'entreprise — pas seulement celui de l'hôte.

**Résolution en deux temps** :

1. **Hôte / VM `podman machine`** (prérequis — sinon `podman build`/`pull` échouent avant même d'atteindre un Dockerfile de ce projet) :
   - Linux natif : `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract` (Fedora/RHEL), ou `/usr/local/share/ca-certificates/` + `update-ca-certificates` (Debian/Ubuntu).
   - macOS/Windows (`podman machine`) : la CA doit être installée **dans la VM**, pas sur l'hôte — `podman machine ssh`, puis même procédure que Linux natif ci-dessus. ⚠️ Non persistant : `podman machine rm`/`init` recrée une VM vierge, il faut la réinstaller après. Voir [docs/macos.md](macos.md) / [docs/windows.md](windows.md).

2. **Images du projet** : déposez le certificat de la CA d'entreprise (format PEM, extension `.crt`) dans `gateway-base/certs/` **et** `workspace-base/certs/` (dossiers vides par défaut, ignorés par git — voir `.gitignore`), puis forcez un rebuild sans cache. `build_images()` (`scripts/orchestrator.py`) relance bien les 4 `podman build` à chaque `run.sh up`/`shell`/`test`, mais avec le cache de layers Docker/Podman activé : `--no-cache` reste nécessaire ici non pas pour forcer la reconstruction, mais pour rafraîchir des étapes qui, elles, resteraient en cache alors qu'elles doivent se rejouer (ex. `apk upgrade`/`apt-get update`) — le `COPY` du certificat invalide déjà de lui-même les étapes qui le suivent :
   ```bash
   podman build --no-cache -t ia-dev-containers-gateway-base:latest   gateway-base/
   podman build --no-cache -t ia-dev-containers-workspace-base:latest workspace-base/
   ```
   Vérification : `podman run --rm --user 1000:1000 ia-dev-containers-workspace-base:latest grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt` doit afficher un compte supérieur à celui obtenu sans le fichier déposé.

**Cas non couvert** : si le réseau exige en plus un **proxy HTTP(S) explicite obligatoire** pour toute sortie (le gateway ne peut pas joindre internet directement, même avec la CA en place), il faudrait chaîner Squid vers ce proxy amont (`cache_peer` dans `gateway-base/config/squid.conf`) — non implémenté ici, à traiter séparément si besoin confirmé.

**Registre privé/auto-signé** (non applicable aujourd'hui — le projet ne pull que depuis Docker Hub public) : Podman a son propre mécanisme, indépendant de ce qui précède — `/etc/containers/certs.d/<host[:port]>/ca.crt` (rootful) ou `~/.config/containers/certs.d/<host[:port]>/ca.crt` (rootless).

---

## Mettre à jour une copie déployée

Le modèle de déploiement de ce projet est la copie (`mon-projet/ia-dev-containers/`), pas un sous-module git ni un package versionné : il n'y a donc pas d'historique de mise à jour automatique. Procédure recommandée — bon sens, pas une commande outillée ni testée par ce projet (voir `CLAUDE.md` : ne rien affirmer de vérifié qui ne l'est pas) :

1. **Identifiez ce qui est spécifique à votre copie**, à ne jamais écraser : `clients/<client>/gateway/config/allowed-urls.txt` (votre allowlist), `clients/<client>/.env` (vos secrets en repli), tout client que vous auriez ajouté vous-même sous `clients/<nouveau-client>/`, et `clients/<client>/.devcontainer/devcontainer.json` (**généré** par `run.sh up`, ne jamais le fusionner à la main — il sera régénéré à l'étape 4).
2. Tout le reste (`scripts/`, `gateway-base/`, `workspace-base/`, `clients/*/scripts/{lib.sh,run.sh}` et `clients/*/workspace/Dockerfile` pour les clients déjà fournis) est générique et peut être remplacé intégralement par la nouvelle version.
3. Récupérez la nouvelle version (`git clone`/`git pull` du dépôt source ailleurs, ou archive), puis copiez par-dessus votre copie déployée en excluant les chemins de l'étape 1, par exemple :
   ```bash
   rsync -av --delete \
     --exclude 'clients/*/gateway/config/allowed-urls.txt' \
     --exclude 'clients/*/.env' \
     --exclude 'clients/*/.devcontainer/' \
     /chemin/vers/nouvelle-version/ mon-projet/ia-dev-containers/
   ```
   Si votre copie est déjà suivie par le git de `mon-projet` (recommandé), `git diff` avant de committer montre exactement ce qui change — relisez-le, en particulier tout ce qui touche à `gateway-base/`, `workspace-base/` (durcissement) et `scripts/security-tests.sh` (garanties vérifiées).
4. **Régénérez et validez aux deux niveaux**, pas seulement une relecture du diff : `./scripts/run.sh down --purge-network && ./scripts/run.sh up && ./scripts/run.sh test` (régénère `devcontainer.json`, force la reconstruction des images, revalide réellement les garanties du sandbox).
