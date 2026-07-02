# =============================================================================
# IA Dev Containers - Image de Base (Alpine 3.20)
# Base commune pour tous les conteneurs clients IA (Mistral Vibe, Copilot, etc.)
# =============================================================================
FROM alpine:3.20

# ---- Arguments ----
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000

# ---- Installation des dépendances communes ----
RUN apk update && apk upgrade && \
    apk add --no-cache \
        bash \
        coreutils \
        findutils \
        git \
        curl \
        openssh-client \
        squid \
        iptables \
        procps \
        net-tools \
        sudo \
        && rm -rf /var/cache/apk/*

# ---- Création de l'utilisateur non-root ----
RUN addgroup -g ${USER_GID} ${USERNAME} && \
    adduser -D -u ${USER_UID} -G ${USERNAME} -s /bin/bash ${USERNAME} && \
    mkdir -p /home/${USERNAME}/.ssh && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# ---- Configuration de sudo (restreint - nécessite mot de passe) ----
RUN echo "${USERNAME} ALL=(ALL) PASSWD: ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

# ---- Configuration du proxy Squid ----
COPY config/proxy/squid.conf /etc/squid/squid.conf
RUN chown -R squid:squid /etc/squid && \
    chmod 640 /etc/squid/squid.conf && \
    mkdir -p /var/log/squid /var/spool/squid && \
    chown squid:squid /var/log/squid /var/spool/squid

# ---- Répertoires pour les dépendances utilisateur ----
RUN mkdir -p /home/${USERNAME}/.local \
    /home/${USERNAME}/.cache \
    /home/${USERNAME}/.npm-global \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.local \
    /home/${USERNAME}/.cache \
    /home/${USERNAME}/.npm-global

# ---- Scripts communs ----
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/setup-proxy.sh /setup-proxy.sh
COPY scripts/security-tests.sh /security-tests.sh
RUN chmod +x /entrypoint.sh /setup-proxy.sh /security-tests.sh && \
    chown ${USERNAME}:${USERNAME} /entrypoint.sh /setup-proxy.sh /security-tests.sh

# ---- Restrictions de sécurité ----
RUN chmod 000 /run/docker.sock /run/podman/podman.sock 2>/dev/null || true
RUN chmod 000 /dev/kmsg /dev/mem /dev/kmem 2>/dev/null || true
RUN chmod 555 /usr/bin/sudo 2>/dev/null || true

# ---- Variables d'environnement communes ----
ENV HOME=/home/${USERNAME}
ENV HTTP_PROXY=http://localhost:3128
ENV HTTPS_PROXY=http://localhost:3128
ENV NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
ENV WORKSPACE=/workspace
ENV IA_CLIENT=unknown

# ---- Configuration finale ----
USER ${USERNAME}
WORKDIR /workspace
VOLUME /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
