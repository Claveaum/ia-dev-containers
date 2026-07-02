# Windows — guide de plateforme

> ⚠️ **Expérimental, non vérifié sur matériel réel.** Ce guide est basé sur l'analyse de l'architecture de `podman machine`/WSL2 (voir sources en bas de page) et sur un bug amont documenté, pas sur une exécution effective — cette machine de développement est un environnement Linux sans accès à du matériel Windows. Voir le [tableau Plateformes hôte](../README.md#️-plateformes-hôte) du README racine.

Contrairement à macOS, il y a un vrai choix à faire ici — ce guide ne le masque pas.

## Option A — Podman Desktop / `podman machine` (provider `wsl`, par défaut)

Onboarding le plus simple : installation GUI, gestion de la VM intégrée.

```powershell
# Installer Podman Desktop, ou :
winget install RedHat.Podman
podman machine init
podman machine start
```

**⚠️ Bug amont connu et actif** ([containers/podman#25201](https://github.com/containers/podman/issues/25201), ouvert 2025-02-03, toujours ouvert au moment de cette recherche) : le driver de pare-feu par défaut de `netavark` (`nftables`) échoue dans une VM `podman machine` provider `wsl`, ce qui peut faire échouer `podman network create --internal` lui-même — pas seulement notre Phase durcie optionnelle (`GATEWAY_HARDENED=1`). Si `./scripts/run.sh up` échoue à la création du réseau avec une erreur `nftables`, voir la [section Dépannage du README racine](../README.md#-dépannage) pour le contournement (`firewall_driver = "iptables"`). **Appliquez ce contournement avant votre premier `run.sh up`**, pas après avoir cru à un bug de ce projet.

## Option B — Podman installé nativement dans une distribution WSL2 (recommandée par défaut)

```powershell
wsl --install
```
Puis, dans le shell Ubuntu-on-WSL2 :
```bash
sudo apt update && sudo apt install -y podman
```

Aucun `podman machine` ici : WSL2 fournit déjà un vrai noyau Linux, donc Podman y tourne exactement comme sur Linux natif — ce chemin contourne entièrement le bug #25201 (spécifique au *provider* `podman machine`, pas à WSL2 lui-même) et réutilise ce dépôt sans aucune adaptation. C'est le chemin recommandé par défaut, sauf si vous tenez spécifiquement à l'interface graphique de Podman Desktop.

## Utilisation (identique aux deux options, une fois Podman disponible)

Comme sur Linux/macOS, `ia-dev-containers` doit être copié à la racine du
projet à sandboxer avant tout `run.sh` (voir le [README racine](../README.md#-utilisation-rapide-mistral-vibe-cli)) :

```bash
# Depuis la racine de VOTRE projet (pas ce dépôt) :
cp -r /chemin/vers/ia-dev-containers .
cd ia-dev-containers/clients/mistral-vibe   # ou clients/copilot
./scripts/run.sh doctor
./scripts/run.sh up
./scripts/run.sh shell
```

Un vrai bash est nécessaire dans les deux cas : le shell WSL2 (Option B, ou Option A si vous utilisez l'intégration WSL de Podman Desktop) est un bash/coreutils complet par construction ; Git Bash (bundlé avec "Git for Windows") fonctionne aussi si vous utilisez Podman Desktop sans WSL2. Les `run.sh` sont compatibles bash 3.2 (voir la [note équivalente côté macOS](macos.md#compatibilité-bash-des-scripts-runsh) — même correctif, vérifié via un vrai bash 3.2 dans ce sandbox), donc aucune version de bash récente n'est requise ici non plus.

## Check-list de validation à faire sur matériel réel (non exécutée dans cette session)

**Option B en premier — plus haute confiance** : mêmes commandes que la [check-list macOS](macos.md#check-list-de-validation-à-faire-sur-matériel-réel-non-exécutée-dans-cette-session) (points 1 à 7, sans les spécificités VM), exécutées depuis le shell WSL2. Comme c'est un vrai noyau Linux dessous, "fait" = mêmes critères de réussite que Linux ; ça ne devrait nécessiter qu'une passe de fumée, pas de débogage.

**Option A** :
1. Vérifier **avant tout le reste** que `podman network create --internal --subnet 10.89.0.0/24 test-net` réussit tout court — c'est le cœur du risque #25201.
2. Si ça échoue, appliquer le contournement `firewall_driver="iptables"`, `podman machine stop && podman machine start`, réessayer.
3. Une fois la création de réseau confirmée, dérouler la même check-list que macOS (3 tests réseau, deux phases, deux clients, en simultané).
4. **Revérifier spécifiquement l'échec d'accès direct sous le driver `iptables`** : passer de `netavark` à `iptables` change le mécanisme d'application de l'isolation réseau — "ça marchait sous netavark" ne prouve rien sous `iptables`.
5. Revérifier l'état de [#25201](https://github.com/containers/podman/issues/25201) avant de commencer : il a pu être corrigé en amont depuis cette recherche (2026-07), ce qui simplifierait ou éliminerait le contournement.

**"Fait" pour Windows** = Option B entièrement validée (devient le chemin recommandé documenté), et Option A explicitement confirmée "fonctionne nativement" ou "fonctionne avec le contournement iptables" — pas laissée comme une inconnue ouverte.

Une fois validé, mettre à jour le [tableau Plateformes hôte](../README.md#️-plateformes-hôte) du README racine.

## Sources

- [containers/podman#25201 — Using nftables on a Windows WSL machine (amd64) doesn't work](https://github.com/containers/podman/issues/25201)
- [Machine Providers: QEMU, Apple HV, Hyper-V & WSL](https://deepwiki.com/podman-container-tools/podman/8.1-machine-providers:-qemu-apple-hv-hyper-v-and-wsl)
