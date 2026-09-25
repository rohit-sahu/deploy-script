#!/bin/sh
set -eu

: "${DOMAIN:?DOMAIN is required}"
export DOMAIN

VARS='${DOMAIN}'

# Drop the stock example config (conflicts with our server_name on :80).
rm -f /etc/nginx/conf.d/default.conf

# Bootstrap config only serves the ACME challenge + HTTP->HTTPS redirect,
# since the certificate doesn't exist yet on first boot.
envsubst "$VARS" < /etc/nginx/templates/app.conf.template > /etc/nginx/conf.d/app.conf

# Add the HTTPS server block once Caddy has issued a certificate, then
# reload nginx to pick it up. Afterwards, reload periodically to also pick
# up renewed certificates. Caddy stores real ACME certs and its internal/
# local-testing CA certs in separate directories (the latter under
# .../certificates/local/); LOCAL_CERT_MODE picks the matching one, so a
# leftover self-signed cert from a previous `--local` run for this same
# domain is never mistaken for (or vice versa) a real one.
(
	echo "Waiting for certificate for ${DOMAIN}..."
	cert_file=""
	while [ -z "$cert_file" ]; do
		if [ "${LOCAL_CERT_MODE:-0}" = "1" ]; then
			cert_file="$(find /caddy-data/caddy/certificates/local -type f -name "${DOMAIN}.crt" 2>/dev/null | head -n1)"
		else
			cert_file="$(find /caddy-data/caddy/certificates -type f -name "${DOMAIN}.crt" -not -path '*/local/*' 2>/dev/null | head -n1)"
		fi
		[ -n "$cert_file" ] || sleep 3
	done
	key_file="${cert_file%.crt}.key"

	# CLOUDFLARE_PROXIED=1 switches to the template that trusts
	# CF-Connecting-IP via ngx_http_realip_module (only safe when Cloudflare
	# proxied/orange-cloud DNS is actually in front of this nginx AND 443 is
	# firewalled to Cloudflare's ranges -- see RUNNING.md). Default (unset/0)
	# keeps treating this nginx as the first hop from the public internet.
	if [ "${CLOUDFLARE_PROXIED:-0}" = "1" ]; then
		https_template=/etc/nginx/templates/https.cloudflare.conf.template
		echo "CLOUDFLARE_PROXIED=1: trusting CF-Connecting-IP via realip module."
	else
		https_template=/etc/nginx/templates/https.conf.template
	fi

	CERT_FILE="$cert_file" KEY_FILE="$key_file" envsubst "$VARS \${CERT_FILE} \${KEY_FILE}" \
		< "$https_template" > /etc/nginx/conf.d/https.conf
	echo "Certificate found at ${cert_file}, enabling HTTPS server block."
	until nginx -s reload 2>/dev/null; do
		sleep 1
	done

	while :; do
		sleep 12h
		nginx -s reload 2>/dev/null || true
	done
) &


exec nginx -g "daemon off;"
