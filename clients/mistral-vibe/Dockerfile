# =============================================================================
# Mistral Vibe CLI - Conteneur de développement sécurisé
# 
# Objectif : Permettre l'utilisation de Mistral Vibe CLI dans un environnement
#           isolé et sécurisé pour le développement local.
# 
# Caractéristiques :
# - Python 3.11 + pip
# - Utilisateur non-root
# - Filesystem en lecture seule (sauf /workspace et ~/.local)
# - Proxy Squid pour filtrer les URLs
# - Installation de paquets via pip install --user
# =============================================================================

FROM ia-dev-containers-base:latest

# ---- Installation de Python 3.11 et ses dépendances ----
RUN apk add --no-cache \
    python3.11 \
    py3.11-pip \
    py3.11-wheel \
    python3.11-dev \
    build-base \
    linux-headers \
    && pip install --upgrade pip setuptools wheel \
    && rm -rf /var/cache/apk/*

# ---- Configuration pour pip install --user ----
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
ENV PIP_USER=1
ENV PYTHONUSERBASE="/home/${USERNAME}/.local"
ENV PYTHONUNBUFFERED=1

# ---- Copier la configuration spécifique à Mistral Vibe ----
COPY config/allowed-urls.txt /etc/squid/allowed-urls.txt
RUN chown squid:squid /etc/squid/allowed-urls.txt && \
    chmod 640 /etc/squid/allowed-urls.txt

# ---- Variables spécifiques ----
ENV IA_CLIENT=mistral-vibe
ENV MISTRAL_API_URL=https://api.mistral.ai

# ---- Volumes pour les dépendances Python ----
VOLUME /home/${USERNAME}/.local
VOLUME /home/${USERNAME}/.cache
