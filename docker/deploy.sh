#!/bin/bash

######################################################################
# Deploy some infrastructure so that we can test the plugin's behavior
######################################################################

#
# Ensure that we are in the folder containing this script
#
cd "$(dirname "${BASH_SOURCE[0]}")"

#
# Get command line arguments
#
PROFILE=$1
if [ "$PROFILE" != 'openresty' ] && [ "$PROFILE" != 'kong' ]; then
  echo "Please specify 'openresty' or 'kong' as a command line argument, eg './deploy.sh openresty'"
  exit 1
fi

#
# Supply the 32 byte encryption key for AES256 as an environment variable
#
export ENCRYPTION_KEY=$(openssl rand 32 | xxd -p -c 64)
echo -n $ENCRYPTION_KEY > encryption.key

#
# For Kong we must update a template file
#
if [ "$PROFILE" == 'kong' ]; then
  envsubst < kong/kong.template.yml > ./kong/kong.yml
fi

#
# Deploy the system
#
docker compose --profile "$PROFILE" --project-name oauthproxy up --build --force-recreate