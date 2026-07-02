#!/bin/sh
set -eu

echo "[gateway] role=${IA_ROLE:-gateway} uid=$(id -u)"

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
    squid -k parse -f /etc/squid/squid.conf

    echo "[gateway] abandon des privilèges vers nobody:nobody, démarrage de Squid..."
    exec su-exec nobody:nobody squid -N -f /etc/squid/squid.conf
else
    # ---- Phase simple : déjà lancé non-root (podman run --user 65534:65534),
    # pas de nftables possible (pas de NET_ADMIN), Squid démarre directement.
    echo "[gateway] déjà non-root, pas de nftables (capacité NET_ADMIN absente)"
    squid -k parse -f /etc/squid/squid.conf
    exec squid -N -f /etc/squid/squid.conf
fi
