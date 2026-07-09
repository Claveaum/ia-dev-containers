#!/bin/sh
set -eu

echo "[gateway] role=${IA_ROLE:-gateway} uid=$(id -u)"

# /etc/squid/squid.conf est en lecture seule (--read-only) : si
# GATEWAY_DNS_SERVERS surcharge les résolveurs par défaut (1.1.1.1 9.9.9.9,
# ex. domaine visible uniquement depuis un DNS interne d'entreprise), la
# config effective est régénérée sous /tmp (seul chemin inscriptible ici).
SQUID_CONF=/etc/squid/squid.conf
if [ -n "${GATEWAY_DNS_SERVERS:-}" ]; then
    echo "[gateway] dns_nameservers surchargé : ${GATEWAY_DNS_SERVERS}"
    SQUID_CONF=/tmp/squid.conf
    sed "s/^dns_nameservers .*/dns_nameservers ${GATEWAY_DNS_SERVERS}/" \
        /etc/squid/squid.conf > "$SQUID_CONF"
fi

if [ "$(id -u)" = "0" ]; then
    # ---- Phase durcie : on est root-in-userns, on pose les protections
    # puis on abandonne les privilèges définitivement avant de lancer Squid.

    echo "[gateway] vérification de net.ipv4.ip_forward..."
    FWD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
    if [ "$FWD" != "0" ]; then
        echo "[gateway] ERREUR CRITIQUE : ip_forward=$FWD - le gateway ne doit jamais router entre ses deux interfaces." >&2
        exit 1
    fi
    echo "[gateway] ip_forward=0 (ok)"

    if [ "${ENABLE_NFT:-1}" = "1" ]; then
        echo "[gateway] chargement des règles nftables..."
        nft -f /etc/nftables/gateway.nft
    fi

    echo "[gateway] validation de squid.conf..."
    squid -k parse -f "$SQUID_CONF"

    echo "[gateway] abandon des privilèges vers nobody:nobody, démarrage de Squid..."
    exec su-exec nobody:nobody squid -N -f "$SQUID_CONF"
else
    # ---- Phase simple : déjà lancé non-root (podman run --user 65534:65534),
    # pas de nftables possible (pas de NET_ADMIN), Squid démarre directement.
    echo "[gateway] déjà non-root, pas de nftables (capacité NET_ADMIN absente)"
    squid -k parse -f "$SQUID_CONF"
    exec squid -N -f "$SQUID_CONF"
fi
