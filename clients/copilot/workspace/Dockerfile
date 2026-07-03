FROM ia-dev-containers-workspace-base:latest

# ---- Node.js 22+ (exigence de @github/copilot) + npm ----
# @github/copilot n'a qu'une dépendance pure JS (detect-libc) : pas besoin
# de build-base/toolchain de compilation native ici.
RUN apk add --no-cache \
    nodejs \
    npm \
    && rm -rf /var/cache/apk/*

# Installation globale sans root : préfixe pointé vers un répertoire déjà
# créé/chown par workspace-base. Le paquet @github/copilot lui-même N'EST
# PAS installé au build (comme mistral-vibe avec pip) : l'utilisateur
# l'installe au runtime avec `npm install -g @github/copilot`, une fois le
# gateway joignable - pas avant, sinon même piège que HTTP_PROXY figé au
# build (voir workspace-base/Dockerfile).
ENV NPM_CONFIG_PREFIX=/home/devuser/.npm-global
ENV PATH="/home/devuser/.npm-global/bin:${PATH}"
# npm écrit son cache par défaut dans ~/.npm, qui n'est pas un volume monté
# (le filesystem racine est --read-only) : rediriger vers ~/.cache, qui l'est
# (même bug que le volume /workspace root-owned croisé sur mistral-vibe -
# npm ne crée pas son répertoire de cache par défaut tout seul en lecture
# seule, il faut le pointer explicitement vers un chemin inscriptible).
ENV NPM_CONFIG_CACHE=/home/devuser/.cache/npm

# Contexte de build = racine du dépôt (voir build_images() dans
# scripts/orchestrator.sh), pas clients/copilot/ : security-tests.sh est
# partagé entre clients et vit hors de ce dossier.
COPY --chmod=0755 scripts/security-tests.sh /security-tests.sh
COPY clients/copilot/scripts/lib.sh /lib.sh

# Un volume Podman nommé fraîchement créé est vide au premier mount : sans
# ces répertoires déjà présents dans l'image, npm (y compris en --dry-run)
# échoue avec ENOENT sur .npm-global/lib avant même toute tentative
# d'install (repéré via un volume scopé par projet réellement vide, jamais
# vu avant car le volume partagé de dev avait déjà ces dossiers depuis un
# ancien `npm install -g` réel).
#
# ~/.copilot (session, jeton d'auth après /login, logs de @github/copilot) :
# même piège de volume nommé root:root si ce répertoire n'existe pas déjà,
# chowné, dans l'image avant le premier mount.
#
# prepare-state-dir.sh (workspace-base) pose aussi le bit setgid + écriture
# groupe (2775, pas un simple chown) : sans lui, un host dont l'UID diffère
# de celui de devuser (macOS) ne peut pas écrire dans ces répertoires malgré
# son appartenance de groupe via --userns=keep-id (voir ce script pour le
# détail — vécu en prod avec `npm install -g @github/copilot` EACCES sur
# ~/.cache/npm).
RUN /prepare-state-dir.sh \
    /home/devuser/.npm-global/lib \
    /home/devuser/.npm-global/bin \
    /home/devuser/.copilot

VOLUME /home/devuser/.npm-global
VOLUME /home/devuser/.cache
VOLUME /home/devuser/.copilot

# Doit rester la dernière instruction (cf. workspace-base/Dockerfile).
USER devuser
