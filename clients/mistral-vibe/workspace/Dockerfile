FROM ia-dev-containers-workspace-base:latest

# ---- Python 3 + pip, installation utilisateur uniquement ----
# Alpine 3.20 fournit Python 3.12 sous le nom "python3" (pas de paquet
# versionné "python3.11"/"py3.11-*", qui n'existe pas dans ce dépôt).
RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-wheel \
    python3-dev \
    build-base \
    linux-headers \
    && pip install --break-system-packages --upgrade pip setuptools wheel \
    && rm -rf /var/cache/apk/*

ENV PATH="/home/devuser/.local/bin:${PATH}"
ENV PIP_USER=1
ENV PYTHONUSERBASE="/home/devuser/.local"
ENV PYTHONUNBUFFERED=1
# Alpine marque python3 "externally managed" (PEP 668) et bloque pip même
# avec --user. Sans risque ici : PYTHONUSERBASE isole déjà tout dans
# ~/.local, rien n'écrit dans le site-packages système que PEP 668 protège.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

ENV IA_CLIENT=mistral-vibe
ENV MISTRAL_API_URL=https://api.mistral.ai

COPY --chmod=0755 scripts/security-tests.sh /security-tests.sh

VOLUME /home/devuser/.local
VOLUME /home/devuser/.cache

# Doit rester la dernière instruction : tout ce qui précède (apk add,
# COPY racine) a besoin de root. workspace-base ne fixe volontairement pas
# USER pour cette raison (voir son Dockerfile).
USER devuser
