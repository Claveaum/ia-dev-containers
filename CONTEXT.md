# Vocabulaire du domaine — ia-dev-containers

Glossaire du langage ubiquitaire du projet. Complète `CLAUDE.md` (architecture,
conventions) sans le dupliquer — ce fichier nomme les concepts, `CLAUDE.md` dit
où ils vivent dans le code.

## Sandbox

- **gateway** — le conteneur avec accès réseau réel (Squid + allowlist de
  domaines). Ne contient jamais de code du CLI IA.
- **workspace** — le conteneur qui exécute le CLI IA, sans route réseau
  directe vers l'extérieur (réseau Podman `--internal`).
- **allowlist** — liste de domaines autorisés par le gateway
  (`clients/<client>/gateway/config/allowed-urls.txt`), seule variation
  spécifique à un client côté réseau.
- **auto-protection** — bind-mount en lecture seule de `ia-dev-containers/`
  sur lui-même à l'intérieur du workspace, quand cette copie est déployée
  in-tree, pour empêcher le CLI IA de modifier sa propre config sandbox.

## Orchestration côté hôte

- **Mount** — description normalisée d'un montage de fichier partagée entre
  les deux chemins de lancement du workspace : `source` (chemin hôte pour un
  bind, nom de volume Podman pour un volume), `target`, `type`
  (`"bind"` | `"volume"`), `readonly`. Introduit pour que `start_workspace()`
  (flags CLI `-v`) et `devcontainer_mounts_json()` (tableau `mounts` de
  `devcontainer.json`) énumèrent le même jeu de mounts une seule fois
  (`scripts/orchestrator.py:mounts()`) au lieu de le recalculer chacun de
  leur côté. N'inclut pas le mount principal `/workspace` (project_root),
  traité à part par chaque rendu.
- **adaptateur client** — `clients/<nom>/scripts/lib.sh` : données propres à
  un client IA (nom, volume de paquets, extensions VS Code, secrets
  attendus), jamais de logique d'orchestration générique.
