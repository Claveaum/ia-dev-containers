# Registre de paquets d'entreprise (pip / npm)

Par défaut, `mistral-vibe` installe depuis PyPI et `copilot` depuis npmjs.
Si votre entreprise impose un registre privé authentifié (Artifactory,
Nexus, Azure Artifacts, GitHub/GitLab Packages...), vous pouvez le
configurer pour **remplacer** ce registre public par défaut.

## Mise en place

1. **URL du registre** — dans `clients/<client>/scripts/lib.sh`, renseignez :
   ```bash
   REGISTRY_URL="https://pip.mycorp.com/simple/"   # ou https://npm.mycorp.com/
   REGISTRY_USER=""                                  # optionnel, voir plus bas
   ```
   Laisser `REGISTRY_URL` vide désactive entièrement cette fonctionnalité
   (comportement par défaut inchangé).

2. **Jeton/mot de passe** — jamais dans `lib.sh` en clair. Décommentez la
   ligne prévue dans le tableau `SECRETS` du même fichier, puis créez le
   secret Podman :
   ```bash
   # pip (mistral-vibe) : le jeton/mot de passe brut
   printf '%s' 'votre-jeton' | podman secret create mistral-vibe-registry-token -
   # npm (copilot) : le blob Basic auth déjà encodé (voir plus bas pourquoi)
   printf '%s' 'utilisateur:motdepasse' | base64 -w0 | podman secret create copilot-registry-token -
   ```
   `./scripts/run.sh secrets` confirme que `REGISTRY_TOKEN` est bien défini.
   Repli possible sur `.env` (`REGISTRY_TOKEN=...`) comme pour les autres
   secrets, avec le même avertissement : la valeur apparaît alors en clair
   dans `podman inspect`.

3. **Allowlist du gateway** — ajoutez le domaine du registre à
   `clients/<client>/gateway/config/allowed-urls.txt` (voir
   [docs/troubleshooting.md](troubleshooting.md)). Si le domaine public par
   défaut (`pypi.org`, `registry.npmjs.org`) n'est alors plus joignable
   depuis ce registre, mettez aussi à jour `TEST_DOMAIN_PRIMARY` dans
   `lib.sh` pour que `./scripts/run.sh test` reste pertinent.

4. **Reconstruire et lancer** :
   ```bash
   ./scripts/run.sh up && ./scripts/run.sh shell
   ```

## Ce qui se passe au démarrage du workspace

`workspace-base/scripts/entrypoint.sh` source le `lib.sh` du client (déjà
copié dans l'image pour `security-tests.sh`) et, si `REGISTRY_URL` est
défini, appelle `client_configure_registry()` — la seule partie propre à
chaque gestionnaire de paquets :

- **pip** (`mistral-vibe`) : écrit `~/.local/pip.conf` (`index-url`) et
  `~/.local/.netrc` (`machine <host> / login <user> / password <jeton>`).
- **npm** (`copilot`) : écrit `~/.npm-global/.npmrc` avec `registry=...` et
  `//<host>/:_auth=${REGISTRY_TOKEN}` — Basic auth, pas Bearer
  (`_authToken`) : beaucoup de registres npm d'entreprise (Nexus en
  particulier) rejettent `Authorization: Bearer <jeton>` et renvoient 404
  (pas 401) sur une auth mal formée, ce qui ressemble à tort à un paquet
  manquant plutôt qu'à un échec d'authentification. `REGISTRY_TOKEN` est
  donc attendu **déjà encodé** — le blob Basic complet
  (`base64(utilisateur:motdepasse)`), pas le mot de passe brut : voir la
  commande de création du secret à l'étape 2. `REGISTRY_USER` n'est pas
  utilisé pour npm (l'identifiant est déjà dans le blob). Comme pour
  `_authToken` avant, le jeton est écrit en tant que référence littérale
  `${REGISTRY_TOKEN}` : npm l'interpole lui-même depuis l'environnement à la
  lecture de `.npmrc`, il ne touche donc jamais le disque.

Ces fichiers vivent sous `PKG_VOLUME_TARGET`, pas sous `$HOME` : le
conteneur workspace tourne `--read-only`, seuls `PKG_VOLUME_TARGET`,
`EXTRA_VOLUMES` et le volume cache sont inscriptibles. Les variables
pointant dessus (`PIP_CONFIG_FILE`/`NETRC`/`NPM_CONFIG_USERCONFIG`) sont
posées dès `podman run` (voir `EXTRA_ENV` dans `lib.sh`), pas seulement
exportées par `entrypoint.sh` : elles restent donc visibles aussi depuis
`./scripts/run.sh exec` (second shell dans le même workspace), qui hérite
de l'environnement figé à la création du conteneur, pas des `export`
faits ensuite par `entrypoint.sh`.

Vérifié bout en bout (build réel, `podman secret`, `run.sh shell` **et**
`run.sh exec`) sur `mistral-vibe` lors de l'implémentation de cette
fonctionnalité — voir la section Limites connues pour ce qui reste
non couvert.

## Limites connues

- **`devcontainer.json`/VS Code** : n'utilisez pas cette fonctionnalité par
  ce chemin. Le CLI devcontainer démarre le conteneur en écrasant sa
  commande/son point d'entrée par défaut (`overrideCommand`, activé par
  défaut) — `entrypoint.sh`, donc `client_configure_registry()`, **ne
  s'exécute pas du tout** dans une session VS Code, pas seulement
  `REGISTRY_TOKEN` (déjà absent, `devcontainer.json` ne supportant pas
  `podman secret`). `REGISTRY_URL`/`REGISTRY_USER` sont bien reportés dans
  `runArgs` mais restent sans effet tant qu'aucun fichier de config n'est
  généré. Utilisez `./scripts/run.sh shell`/`exec` (CLI) pour cette
  fonctionnalité — cohérent avec le reste de ce projet, où le chemin
  devcontainer.json est documenté comme non vérifié en session réelle.
- Un seul registre par client (pas de registres scopés par paquet côté npm,
  pas d'`extra-index-url` de repli côté pip) : le registre configuré
  **remplace** entièrement le registre public par défaut.
- L'ajout du domaine à l'allowlist reste un geste manuel (comme pour tout
  nouveau domaine, voir [docs/troubleshooting.md](troubleshooting.md)).
