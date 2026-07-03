FROM ia-dev-containers-gateway-base:latest

COPY config/allowed-urls.txt /etc/squid/allowed-urls.txt
# 644, même raisonnement que squid.conf dans gateway-base/Dockerfile.
RUN chmod 644 /etc/squid/allowed-urls.txt
