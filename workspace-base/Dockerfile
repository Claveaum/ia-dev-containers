# =============================================================================
# IA Dev Containers - Workspace (image de base, générique)
#
# Rôle : exécute le CLI IA (non fiable). Aucun accès réseau direct - attaché
# uniquement au réseau interne dédié au projet (scopé par client+projet, voir
# clients/*/scripts/lib.sh), ne peut joindre que le gateway.
# Pas de squid/iptables ici : le filtrage réseau vit entièrement dans le
# conteneur gateway (voir gateway-base/, resté sur Alpine - aucune dépendance
# Node ni raison de bouger un composant audité).
#
# glibc (Debian), pas Alpine (musl) : `@github/copilot` (client Copilot)
# segfault de façon reproductible sur musl/arm64 (constaté sur matériel réel,
# macOS Apple Silicon) - bug upstream connu, non résolu, indépendant de tout
# durcissement de ce sandbox (reproduit y compris hors sandbox, cap-drop=ALL/
# --read-only/--userns=keep-id retirés). Confirmé résolu par un binaire lié à
# glibc avant de migrer ce Dockerfile (voir github/copilot-cli#107). mistral-
# vibe (Python/pip) n'a aucune dépendance à musl - bascule sans régression.
# Pin délibéré sur bookworm-slim (pas `latest`) : reproductibilité des builds,
# et version alignée avec les images node:22-bookworm-slim dont le client
# Copilot copie le runtime Node (voir clients/copilot/workspace/Dockerfile).
# =============================================================================
FROM debian:bookworm-slim

ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# --- Confiance CA d'entreprise (optionnelle) ---
# Contrairement à Alpine (apk, dépôts https://dl-cdn.alpinelinux.org), aucun
# bootstrap de confiance n'est nécessaire ici avant le premier apt-get : les
# dépôts par défaut de l'image `slim` (vérifié : /etc/apt/sources.list.d/) sont
# en `http://deb.debian.org`, l'intégrité des paquets étant garantie par la
# signature GPG du Release (debian-archive-keyring), pas par TLS - une
# interception TLS du réseau d'entreprise n'affecte donc pas apt lui-même.
# certs/ est vide par défaut (.gitkeep) -> simple dépôt ici, repris par
# update-ca-certificates une fois le paquet ca-certificates installé
# ci-dessous -> no-op strict pour qui n'a pas de CA d'entreprise à ajouter.
COPY certs/ /usr/local/share/ca-certificates/

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        bash \
        coreutils \
        findutils \
        git \
        curl \
        openssh-client \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# --- Confiance CA d'entreprise, partie 2/2 ---
# update-ca-certificates (fourni par le paquet ca-certificates installé
# ci-dessus) relit /usr/local/share/ca-certificates/ (déjà rempli par le
# COPY) et régénère /etc/ssl/certs/ca-certificates.crt -> idempotent, no-op
# strict si certs/ est vide.
RUN update-ca-certificates

RUN groupadd -g ${USER_GID} ${USERNAME} && \
    useradd -m -u ${USER_UID} -g ${USERNAME} -s /bin/bash ${USERNAME} && \
    mkdir -p /home/${USERNAME}/.ssh && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# sudo nécessite un mot de passe ET son binaire perd son bit setuid : double
# verrou (défense en profondeur), aucun des deux ne suffirait seul à masquer
# l'autre s'il était mal configuré.
RUN echo "${USERNAME} ALL=(ALL) PASSWD: ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME} && \
    chmod 555 /usr/bin/sudo

COPY scripts/prepare-state-dir.sh /prepare-state-dir.sh
RUN chmod +x /prepare-state-dir.sh

# Seul .cache est réellement générique (CACHE_VOLUME, monté sans condition
# pour tout client — voir scripts/orchestrator.py: mounts()). .local et
# .npm-global sont chacun le PKG_VOLUME_TARGET d'UN SEUL client (mistral-vibe,
# copilot) : les préparer ici les ferait passer pour génériques alors qu'ils
# ne le sont pas — chaque overlay client prépare désormais son propre
# PKG_VOLUME_TARGET (voir clients/*/workspace/Dockerfile), pour qu'un futur
# client avec un PKG_VOLUME_TARGET inédit ne se retrouve pas avec un
# répertoire root:root non préparé au premier montage (voir prepare-state-dir.sh
# pour le piège du volume nommé fraîchement créé).
RUN PREPARE_STATE_DIR_USER=${USERNAME} /prepare-state-dir.sh \
    /home/${USERNAME}/.cache

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown ${USERNAME}:${USERNAME} /entrypoint.sh

ENV HOME=/home/${USERNAME}
ENV WORKSPACE=/workspace
ENV IA_CLIENT=unknown

# HTTP_PROXY/HTTPS_PROXY ne sont PAS fixées ici (ni dans les overlays clients).
# "gateway" ne résout et n'est joignable qu'au runtime, une fois le conteneur
# attaché au réseau interne partagé avec le gateway - pas au moment du build.
# Une ENV figée ici casserait tout `apt-get install`/`pip install` ultérieur
# au build (apt respecte HTTP_PROXY et tenterait de résoudre un hôte
# "gateway" qui n'existe pas encore). Le proxy est injecté uniquement au
# runtime par scripts/orchestrator.py: start_workspace() (proxy_url()).
ENV NO_PROXY=localhost,127.0.0.1

# Certains outils ignorent le magasin système par défaut (CA vendorisée) :
# pointer explicitement vers /etc/ssl/certs/ca-certificates.crt les rend
# cohérents avec lui. Sans CA d'entreprise ajoutée (voir certs/ plus haut),
# ce fichier contient exactement le même jeu de CA publiques qu'avant ->
# aucun changement de comportement pour le cas par défaut.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt

WORKDIR /workspace
# WORKDIR crée /workspace en root (aucun USER actif à ce stade). Les deux
# clients actuels (clients/*/scripts/run.sh) montent toujours PROJECT_ROOT en
# bind-mount sur /workspace au runtime, qui prend le pas sur ce VOLUME — ce
# chown/VOLUME ne sert donc plus de chemin normal aujourd'hui. Conservé comme
# repli inoffensif : si /workspace est un jour lancé sans bind-mount explicite
# (usage manuel, futur client), Podman initialise alors un volume nommé vide
# avec le contenu/propriétaire de l'image à ce chemin, et sans ce chown le
# volume serait root:root, illisible en écriture par devuser au runtime.
RUN chown ${USERNAME}:${USERNAME} /workspace
VOLUME /workspace

# Pas de USER ici volontairement : les overlays clients (ex: clients/*/workspace/
# Dockerfile) ont souvent besoin d'installer des paquets via `apt-get install`
# après ce FROM, ce qui exige root. Chaque overlay client doit terminer par
# `USER ${USERNAME}` une fois ses propres RUN d'installation terminés.

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
