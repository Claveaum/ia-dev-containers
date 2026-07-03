FROM ia-dev-containers-workspace-base:latest

# ---- Python 3 + pip, installation utilisateur uniquement ----
# Debian bookworm (workspace-base) fournit Python 3.11 sous le nom "python3".
# DEBIAN_FRONTEND=noninteractive déjà fixé par workspace-base (hérité).
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    && pip3 install --break-system-packages --upgrade pip setuptools wheel \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/home/devuser/.local/bin:${PATH}"
ENV PIP_USER=1
ENV PYTHONUSERBASE="/home/devuser/.local"
ENV PYTHONUNBUFFERED=1
# Debian (comme Alpine avant) marque python3 "externally managed" (PEP 668)
# et bloque pip même avec --user. Sans risque ici : PYTHONUSERBASE isole déjà
# tout dans ~/.local, rien n'écrit dans le site-packages système que PEP 668
# protège.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

ENV MISTRAL_API_URL=https://api.mistral.ai

# Contexte de build = racine du dépôt (voir build_images() dans
# scripts/orchestrator.sh), pas clients/mistral-vibe/ : security-tests.sh
# est partagé entre clients et vit hors de ce dossier.
COPY --chmod=0755 scripts/security-tests.sh /security-tests.sh
COPY clients/mistral-vibe/scripts/lib.sh /lib.sh

# ~/.local est le PKG_VOLUME_TARGET de ce client (voir scripts/lib.sh) : ni
# générique ni partagé avec copilot, donc préparé ici et non plus dans
# workspace-base/Dockerfile (voir son commentaire) — sans ce
# prepare-state-dir.sh, le premier montage du volume nommé sur ~/.local
# serait root:root, illisible en écriture par pip (même piège que
# ~/.copilot côté client Copilot).
RUN /prepare-state-dir.sh /home/devuser/.local

VOLUME /home/devuser/.local
VOLUME /home/devuser/.cache

# Doit rester la dernière instruction : tout ce qui précède (apt-get install,
# COPY racine) a besoin de root. workspace-base ne fixe volontairement pas
# USER pour cette raison (voir son Dockerfile).
USER devuser
