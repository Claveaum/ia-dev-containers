# macOS — guide de plateforme

> ⚠️ **Expérimental, non vérifié sur matériel réel.** Ce guide est basé sur l'analyse de l'architecture de `podman machine` sur macOS (voir sources en bas de page), pas sur une exécution effective — cette machine de développement est un environnement Linux sans accès à du matériel macOS. Voir le [tableau Plateformes hôte](../README.md#️-plateformes-hôte) du README racine.

## Prérequis

- [Podman Desktop](https://podman-desktop.io/) (installation GUI, gère la VM), **ou** :
  ```bash
  brew install podman
  ```

## Démarrage de la VM

Podman ne tourne jamais nativement sur macOS : toute commande `podman` passe par une VM Linux (`podman machine`).

```bash
podman machine init
podman machine start
```

Provider par défaut : `applehv` sur Apple Silicon (macOS ≥ 13) ou `qemu` sinon. Dans les deux cas, la VM utilise `gvproxy` pour sa propre frontière réseau (VM ↔ hôte ↔ internet), mais *à l'intérieur* de la VM, Podman utilise le même `netavark`/`aardvark-dns` qu'un Linux natif pour son réseau de conteneurs — c'est ce sur quoi repose l'invariant central de ce projet (`podman network create --internal` sans route sortante). Aucune incompatibilité documentée trouvée entre `gvproxy` et les réseaux `--internal` — mais non vérifié empiriquement dans ce projet (voir la check-list de validation ci-dessous).

## Utilisation

Une fois la VM démarrée, tout le reste est identique à Linux — y compris la
copie de `ia-dev-containers` à la racine du projet à sandboxer, requise avant
tout `run.sh` (voir le [README racine](../README.md#-utilisation-rapide-mistral-vibe-cli)) :

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/mistral-vibe   # ou clients/copilot
./scripts/run.sh doctor   # vérifie que la VM est bien détectée
./scripts/run.sh up
./scripts/run.sh shell
```

## `/workspace` est un bind-mount du projet réel — point d'attention macOS spécifique

Ce projet copie `ia-dev-containers` à la racine du projet à sandboxer et monte cette racine directement dans `/workspace` (bind-mount, pas un volume Podman vide) : le CLI IA travaille sur les vrais fichiers. C'est le point le plus susceptible de révéler un écart macOS-spécifique, et **rien ici n'a été vérifié sur matériel réel** : un bind-mount hôte↔VM sur macOS traverse `virtiofs` (ou `9p` selon le provider), une couche de partage de fichiers où les décalages d'UID/GID entre l'utilisateur macOS (souvent UID 501) et l'utilisateur à l'intérieur de la VM sont une source connue de problèmes de permissions. `--userns=keep-id` (déjà utilisé) atténue ça sur Linux natif ; son comportement à travers virtiofs n'est pas documenté et fait partie de la check-list ci-dessous.

`~/.local` (ou `~/.npm-global` pour Copilot) et `~/.cache` restent, eux, des **volumes Podman nommés** (jamais des bind-mounts) : leur stockage vit entièrement à l'intérieur du disque de la VM `podman machine`, sans traverser virtiofs/9p — ils ne sont pas concernés par ce risque.

## Compatibilité bash des scripts `run.sh`

macOS fournit bash 3.2 en `/bin/bash` par défaut (pas de `mapfile`, et — piège plus subtil — sous `set -u`, l'expansion d'un tableau vide `"${arr[@]}"` lève `unbound variable`, contrairement à bash ≥4.4). Les deux `run.sh` en dépendaient (secrets absents, `.env` absent, gateway durci) et auraient planté au tout premier lancement sur macOS. **Vérifié dans ce sandbox** (pas seulement lu dans le code) via `podman run --rm -i docker.io/library/bash:3.2 bash -s < script.sh` reproduisant le chemin vide puis confirmant le correctif (`${arr[@]+"${arr[@]}"}`) ; suite de sécurité complète (14/14, deux phases, deux clients) rejouée sur Linux ensuite sans régression. Ceci ne remplace pas un test sur bash 3.2 réel macOS, mais couvre la même version exacte de l'interpréteur.

## Check-list de validation à faire sur matériel réel (non exécutée dans cette session)

Cette section décrit ce qu'il reste à vérifier — elle n'a pas pu être exécutée ici (pas de matériel macOS disponible).

1. `podman machine init && podman machine start`, puis `./scripts/run.sh doctor` — sortie propre, sans erreur.
2. `cd clients/mistral-vibe && ./scripts/run.sh up` (`GATEWAY_HARDENED=0` par défaut).
3. Les 3 tests réseau obligatoires (mêmes qu'en Linux) :
   ```bash
   ./scripts/run.sh shell -- curl --noproxy '*' --max-time 5 https://1.1.1.1     # doit échouer
   ./scripts/run.sh shell -- curl -x http://gateway:3128 https://github.com      # doit réussir (200)
   ./scripts/run.sh shell -- curl -x http://gateway:3128 https://facebook.com    # doit échouer (403)
   ```
4. `./scripts/run.sh test` (suite complète) → doit passer.
5. Répéter 2-4 avec `GATEWAY_HARDENED=1`, plus `podman exec <nom-du-conteneur-gateway> /gateway-checks.sh` (nom exact via `podman ps` ou `run.sh doctor` ; capacités vides, `ip_forward=0`, squid en `nobody` — mêmes assertions déjà prouvées sur Linux).
6. Répéter toute la séquence pour `clients/copilot`, y compris deux **projets différents simultanément** (comme déjà vérifié sur Linux — voir [Isolation entre projets](../README.md#-isolation-entre-projets)).
7. **Point le plus susceptible de diverger de Linux** : vérifier que `$(id -u):$(id -g)` (UID macOS, ex. 501) donne des permissions saines en écriture/lecture dans `/workspace` à travers virtiofs/9p (bind-mount, pas un volume nommé — voir la section ci-dessus), qu'un fichier créé dans le conteneur est bien visible et possédé correctement côté macOS, et que `--security-opt=label=disable` (no-op attendu, macOS n'a pas SELinux) ne cause pas d'effet de bord inattendu.
8. **"Fait" pour macOS** = tout ce qui précède passe avec la même sémantique pass/fail que Linux (200 / 403 / network unreachable), ou des écarts explicitement documentés qui restent sûrs.

Une fois cette check-list validée, mettre à jour le [tableau Plateformes hôte](../README.md#️-plateformes-hôte) du README racine (✅ Testé au lieu de ⚠️ Expérimental).

## Sources

- [How Podman runs on Macs and other container FAQs](https://www.redhat.com/en/blog/podman-mac-machine-architecture) (Red Hat)
- [How does the machine based on applehv access the ports of the container?](https://github.com/containers/podman/discussions/20757) (containers/podman)
