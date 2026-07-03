# =============================================================================
# IA Dev Containers - Workspace (image de base, générique)
#
# Rôle : exécute le CLI IA (non fiable). Aucun accès réseau direct - attaché
# uniquement au réseau interne dédié au projet (scopé par client+projet, voir
# clients/*/scripts/lib.sh), ne peut joindre que le gateway.
# Pas de squid/iptables ici : le filtrage réseau vit entièrement dans le
# conteneur gateway (voir gateway-base/).
#
# Doit rester >= 3.21 : c'est la première version à fournir Node.js >= 22
# nativement, requis par le client Copilot (mistral-vibe en bénéficie aussi
# sans régression). Bump délibéré 3.21 -> 3.24 (nodejs 22.23.0 -> 24.17.0,
# python3 3.12 -> 3.14) : revalidé en entier après ce bump (les deux
# clients, voir README, section Sécurité).
# =============================================================================
FROM alpine:3.24

# --- Confiance CA d'entreprise (optionnelle), partie 1/2 ---
# Ajout "à la main" AVANT tout apk : sur un réseau qui intercepte le TLS
# (proxy corporate), apk lui-même (dépôts https://dl-cdn.alpinelinux.org)
# doit déjà faire confiance à la CA d'entreprise pour son propre
# `apk update`. ca-certificates-bundle est déjà présent dans l'image de
# base (vérifié), donc `cat` (busybox) suffit ici, pas besoin d'apk avant
# ce point. certs/ est vide par défaut (.gitkeep) -> `find` ne matche rien
# -> no-op strict pour qui n'a pas de CA d'entreprise à ajouter.
COPY certs/ /usr/local/share/ca-certificates/
RUN find /usr/local/share/ca-certificates -maxdepth 1 -name '*.crt' -exec cat {} + \
        >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true

ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000

RUN apk update && apk upgrade && \
    apk add --no-cache \
        ca-certificates \
        bash \
        coreutils \
        findutils \
        git \
        curl \
        openssh-client \
        sudo \
        && rm -rf /var/cache/apk/*

# --- Confiance CA d'entreprise, partie 2/2 ---
# apk upgrade peut avoir régénéré /etc/ssl/certs/ca-certificates.crt depuis
# le seul contenu du paquet ca-certificates-bundle, effaçant l'ajout
# ci-dessus. update-ca-certificates relit /usr/local/share/ca-certificates/
# (déjà rempli par le COPY) et régénère le bundle proprement -> idempotent,
# no-op strict si certs/ est vide.
RUN update-ca-certificates

RUN addgroup -g ${USER_GID} ${USERNAME} && \
    adduser -D -u ${USER_UID} -G ${USERNAME} -s /bin/bash ${USERNAME} && \
    mkdir -p /home/${USERNAME}/.ssh && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# sudo nécessite un mot de passe ET son binaire perd son bit setuid : double
# verrou (défense en profondeur), aucun des deux ne suffirait seul à masquer
# l'autre s'il était mal configuré.
RUN echo "${USERNAME} ALL=(ALL) PASSWD: ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME} && \
    chmod 555 /usr/bin/sudo

RUN mkdir -p /home/${USERNAME}/.local \
    /home/${USERNAME}/.cache \
    /home/${USERNAME}/.npm-global \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.local \
    /home/${USERNAME}/.cache \
    /home/${USERNAME}/.npm-global

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown ${USERNAME}:${USERNAME} /entrypoint.sh

ENV HOME=/home/${USERNAME}
ENV WORKSPACE=/workspace
ENV IA_CLIENT=unknown

# HTTP_PROXY/HTTPS_PROXY ne sont PAS fixées ici (ni dans les overlays clients).
# "gateway" ne résout et n'est joignable qu'au runtime, une fois le conteneur
# attaché au réseau interne partagé avec le gateway - pas au moment du build.
# Une ENV figée ici casserait tout `apk add`/`pip install` ultérieur au build
# (apk respecte HTTP_PROXY et tenterait de résoudre un hôte "gateway" qui
# n'existe pas encore). Le proxy est injecté uniquement au runtime par
# scripts/orchestrator.sh: start_workspace() (proxy_url() dans scripts/common.sh).
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
# Dockerfile) ont souvent besoin d'installer des paquets via `apk add` après ce
# FROM, ce qui exige root. Chaque overlay client doit terminer par
# `USER ${USERNAME}` une fois ses propres RUN d'installation terminés.

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
