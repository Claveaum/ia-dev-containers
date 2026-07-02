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

ENV IA_CLIENT=copilot

COPY --chmod=0755 scripts/security-tests.sh /security-tests.sh

VOLUME /home/devuser/.npm-global
VOLUME /home/devuser/.cache

# Doit rester la dernière instruction (cf. workspace-base/Dockerfile).
USER devuser
