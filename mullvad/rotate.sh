#!/bin/sh

# Account number file
ACCOUNT_FILE="/home/user/mullvad.txt"

# Wireguard configuration file
CONFIG="/etc/wireguard/wg0.conf"

# Mullvad certificate
MULLVAD_CERT="certificate.pem"

# Escape special characters for sed
escape() {
	echo $1 | sed -e 's/[\/&]/\\&/g'
}

# Get account number
if [ -r $ACCOUNT_FILE ]; then
	ACCOUNT="$(cat $ACCOUNT_FILE | sed 's/\s//g')"
else
	echo "[+] Error: No account number found"
	exit 1
fi
echo "[+] Using account $ACCOUNT"

# Get existing private key
OLD_PRIVATE_KEY="$(cat $CONFIG | sed -rn 's/^PrivateKey *= *([a-zA-Z0-9+/]{43}=) *$/\1/ip;T;q')"
if [ -z $OLD_PRIVATE_KEY ]; then
	echo "[+] Error: Wireguard private key not found"
	exit 1
fi

# Get public key
OLD_PUBLIC_KEY="$(printf '%s\n' "$OLD_PRIVATE_KEY" | wg pubkey)"
if [ -z $OLD_PUBLIC_KEY ]; then
	echo "[+] Error: Failed to get public key"
	exit 1
fi
echo "[+] Found public key $OLD_PUBLIC_KEY"

# Generate new private key
echo "[+] Generating new private key"
NEW_PRIVATE_KEY=$(wg genkey)
if [ -z $NEW_PRIVATE_KEY ]; then
	echo "[+] Error: Failed to generate new private key"
	exit 1
fi

# Generate new public key
NEW_PUBLIC_KEY=$(echo $NEW_PRIVATE_KEY | wg pubkey)
if [ -z $NEW_PUBLIC_KEY ]; then
	echo "[+] Error: Failed to generate new public key"
	exit 1
fi
echo "[+] Generated new public key $NEW_PUBLIC_KEY"

# Get authorization token
echo "[+] Getting Mullvad auth token"
ACCOUNT_RES=$(curl -s --cacert $MULLVAD_CERT https://api.mullvad.net/www/accounts/$ACCOUNT/)
AUTH_TOKEN=$(echo $ACCOUNT_RES | jq -r '.auth_token')
if [ -z $AUTH_TOKEN ]; then
	echo "[+] Error: Failed to get account token"
	exit 1
fi

# Check if existing key is in Mullvad account
ACCOUNT_KEYS=$(echo $ACCOUNT_RES | jq -r '.account.wg_peers[].key.public')
if grep -q $OLD_PUBLIC_KEY <<< $ACCOUNT_KEYS; then
	echo "[+] Removing old key from Mullvad"

	curl -s --cacert $MULLVAD_CERT \
		-H "Content-Type: application/json" \
		-H "Authorization: Token $AUTH_TOKEN" \
		-d '{"pubkey": "'$OLD_PUBLIC_KEY'"}' \
		https://api.mullvad.net/www/wg-pubkeys/revoke/
fi

# Submit new key to Mullvad
echo "[+] Submitting new Wireguard key to Mullvad"
IPS=$(curl -s --cacert $MULLVAD_CERT \
	-d account="$ACCOUNT" \
	--data-urlencode pubkey="$NEW_PUBLIC_KEY" \
	https://api.mullvad.net/wg/)
if ! printf '%s\n' "$IPS" | grep -E '^[0-9a-f:/.,]+$' >/dev/null
then
        echo "[+] Error: Failed to submit new Wireguard key to Mullvad"
	echo "[+] Response: $IPS"
	exit 1
fi
echo "[+] New Wireguard IPs are $IPS"

# Backup Wireguard config
cp $CONFIG old_confg

# Change Wireguard config
echo "[+] Updating Wireguard config $CONFIG"
ESCAPED_IPS=$(escape $IPS)
ESCAPED_PRIVATE_KEY="$(escape $NEW_PRIVATE_KEY)"
sed -i -r "s/PrivateKey = (.+)$/PrivateKey = $ESCAPED_PRIVATE_KEY/" $CONFIG
sed -i -r "s/Address = (.+)$/Address = $ESCAPED_IPS/" $CONFIG

# Wait 60 seconds
echo "[+] Waiting 60 seconds..."
sleep 60

# Restart Wireguard
echo "[+] Restarting Wireguard"
systemctl restart wg-quick@wg0
