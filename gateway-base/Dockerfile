# =============================================================================
# IA Dev Containers - Gateway (image de base, générique)
#
# Rôle : seul conteneur à posséder un accès réseau réel. Fait tourner Squid
# et applique l'allowlist de domaines. Ne contient jamais de code du CLI IA.
# Les clients (ex: mistral-vibe) COPY leur propre allowed-urls.txt par-dessus.
# =============================================================================
FROM alpine:3.20

RUN apk update && apk upgrade && \
    apk add --no-cache squid nftables su-exec curl && \
    rm -rf /var/cache/apk/*

# nobody:nobody existe déjà normalement dans Alpine, mais on le garantit
# explicitement plutôt que de supposer qu'il est présent.
RUN id nobody 2>/dev/null || (addgroup -g 65534 nobody && \
    adduser -D -H -u 65534 -G nobody -s /sbin/nologin nobody)

COPY config/squid.conf /etc/squid/squid.conf
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/gateway.nft /etc/nftables/gateway.nft

# 644 (pas 640) : en Phase 1 Squid démarre directement en "nobody", qui
# doit pouvoir lire ce fichier sans chown préalable. Aucun secret dedans
# (seulement des ACL), donc lisible par tous est acceptable.
RUN chmod 644 /etc/squid/squid.conf && \
    chmod +x /entrypoint.sh

# Pas de USER ici : entrypoint.sh décide au runtime (root -> nftables puis
# abandon de privilèges, ou déjà non-root -> lancement direct de Squid).
# Voir clients/*/scripts/run.sh (GATEWAY_HARDENED=0|1).

ENV IA_ROLE=gateway
EXPOSE 3128
ENTRYPOINT ["/entrypoint.sh"]
