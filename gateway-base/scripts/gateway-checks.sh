#!/bin/sh
# Vérifications côté gateway, à lancer depuis l'hôte via :
#   podman exec <gateway-container> /gateway-checks.sh
# (copié dans l'image via COPY — voir le README, section Dépannage, pour
# l'usage). Générique : aucun contenu spécifique à un client, partagé par
# tous via gateway-base/ plutôt que dupliqué dans chaque clients/<client>/.
echo -n "utilisateur effectif de squid : "; ps -o user,comm | grep squid | awk '{print $1}' | head -1
echo -n "ip_forward                    : "; cat /proc/sys/net/ipv4/ip_forward
echo -n "capacités du process 1        : "; grep CapEff /proc/1/status 2>/dev/null || echo "n/a"
