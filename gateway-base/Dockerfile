# =============================================================================
# IA Dev Containers - Gateway (image de base, générique)
#
# Rôle : seul conteneur à posséder un accès réseau réel. Fait tourner Squid
# et applique l'allowlist de domaines. Ne contient jamais de code du CLI IA.
# Les clients (ex: mistral-vibe) COPY leur propre allowed-urls.txt par-dessus.
# =============================================================================
# Bump délibéré 3.20 -> 3.24 (squid 6.x -> 7.5, nftables -> 1.1.6, su-exec
# 0.3, sudo 1.9.17_p2) : revalidé en entier après ce bump (les deux phases,
# les deux clients, GATEWAY_HARDENED=1 inclus — voir README, section
# Sécurité). Même version que workspace-base désormais : plus de raison de
# les faire diverger (l'asymétrie précédente ne venait que d'un bump
# workspace-base ponctuel pour Node.js, voir ce fichier).
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

RUN apk update && apk upgrade && \
    apk add --no-cache ca-certificates squid nftables su-exec curl && \
    rm -rf /var/cache/apk/*

# --- Confiance CA d'entreprise, partie 2/2 ---
# apk upgrade peut avoir régénéré /etc/ssl/certs/ca-certificates.crt depuis
# le seul contenu du paquet ca-certificates-bundle, effaçant l'ajout
# ci-dessus. update-ca-certificates relit /usr/local/share/ca-certificates/
# (déjà rempli par le COPY) et régénère le bundle proprement -> idempotent,
# no-op strict si certs/ est vide.
RUN update-ca-certificates

# nobody:nobody existe déjà normalement dans Alpine, mais on le garantit
# explicitement plutôt que de supposer qu'il est présent.
RUN id nobody 2>/dev/null || (addgroup -g 65534 nobody && \
    adduser -D -H -u 65534 -G nobody -s /sbin/nologin nobody)

COPY config/squid.conf /etc/squid/squid.conf
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/gateway.nft /etc/nftables/gateway.nft
# Aucun contenu spécifique à un client (voir son propre commentaire) :
# copié ici une fois plutôt que dupliqué dans chaque clients/<client>/gateway/.
COPY scripts/gateway-checks.sh /gateway-checks.sh

# 644 (pas 640) : en Phase 1 Squid démarre directement en "nobody", qui
# doit pouvoir lire ce fichier sans chown préalable. Aucun secret dedans
# (seulement des ACL), donc lisible par tous est acceptable.
RUN chmod 644 /etc/squid/squid.conf && \
    chmod +x /entrypoint.sh /gateway-checks.sh

# Pas de USER ici : entrypoint.sh décide au runtime (root -> nftables puis
# abandon de privilèges, ou déjà non-root -> lancement direct de Squid).
# Voir scripts/orchestrator.sh: start_gateway() (GATEWAY_HARDENED=0|1).

ENV IA_ROLE=gateway
EXPOSE 3128
ENTRYPOINT ["/entrypoint.sh"]
