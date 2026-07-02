# =============================================================================
# IA Dev Containers - Workspace (image de base, générique)
#
# Rôle : exécute le CLI IA (non fiable). Aucun accès réseau direct - attaché
# uniquement au réseau interne ia-gw-internal, ne peut joindre que le gateway.
# Pas de squid/iptables ici : le filtrage réseau vit entièrement dans le
# conteneur gateway (voir gateway-base/, resté en 3.20 - aucune dépendance
# Node côté gateway, pas de raison de faire bouger un composant audité).
#
# 3.21 (et non 3.20) car le client Copilot a besoin de Node.js >= 22, que
# seul Alpine >= 3.21 fournit nativement (`nodejs` = 22.23.0-r0).
# =============================================================================
FROM alpine:3.21

ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000

RUN apk update && apk upgrade && \
    apk add --no-cache \
        bash \
        coreutils \
        findutils \
        git \
        curl \
        openssh-client \
        sudo \
        && rm -rf /var/cache/apk/*

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
# clients/*/scripts/run.sh (proxy_url() dans lib.sh).
ENV NO_PROXY=localhost,127.0.0.1

WORKDIR /workspace
# WORKDIR crée /workspace en root (aucun USER actif à ce stade). Un volume
# nommé est initialisé, à sa création, avec le contenu/propriétaire du
# répertoire de l'image à ce chemin - sans ce chown, le volume serait
# root:root et devuser ne pourrait pas y écrire au runtime.
RUN chown ${USERNAME}:${USERNAME} /workspace
VOLUME /workspace

# Pas de USER ici volontairement : les overlays clients (ex: clients/*/workspace/
# Dockerfile) ont souvent besoin d'installer des paquets via `apk add` après ce
# FROM, ce qui exige root. Chaque overlay client doit terminer par
# `USER ${USERNAME}` une fois ses propres RUN d'installation terminés.

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
