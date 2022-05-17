#!/bin/bash

LINE_WIDTH=60
function ww() {
    cat | fold -s -w $LINE_WIDTH
}
function pw() {
    head -c $1 /dev/urandom | base64 -w 0 | head -c $1
}

echo -n "Please enter the base directory in which all bind-mounts will be placed: ($(pwd))" | ww
read BASE_DIR
if [ -z $BASE_DIR ]; then
    BASE_DIR=$(pwd)
fi

echo "The linuxserver.io-images require a user that will be the owner of the bind-mounted data within the docker containers. If you give a user name that does not exist, a new one will be created." | ww
echo -n "User name: "
read user;

if [ ! id "$user" &>/dev/null ]; then
    echo "User does not exist. Creating a new one."
    useradd -d $BASE_DIR \
            -c "docker user" \
            --no-create-home \
            --system \
            --user-group \
            $user
fi

uid=$(id -u $user)
gid=$(id -g $user)

mkdir -p $BASE_DIR && cd $BASE_DIR
git clone https://github.com/xwst/home-server.git
chown -R $uid:$gid $BASE_DIR


echo "Please enter a single domain under which the server is accessible. Additional domains need to be configured manually later." | ww
echo -n "Domain: "
read domain;

echo "Creating environment file for docker-compose. Timezone is copied from host!" | ww
echo "BASE_DIR=$BASE_DIR" > .env
echo -en "PUID=$uid\nPGID=$gid\nMYDOMAIN=$domain\nTIMEZONE=" >> .env
cat /etc/timezone >> .env
chmod 600 .env
echo "DB_ROOT_PW=$(pw 20)" >> .env
echo "DB_NEXTCLOUD_PW=$(pw 20)" >> .env

echo "Starting server to continue with configuration." | ww
docker-compose up -d

echo -n "Waiting for bind-mounts to be ready." | ww
PROXY_CONF=$BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf
NC_CONF=$BASE_DIR/nextcloud/config/www/nextcloud/config/config.php
while [ ! -f "$PROXY_CONF.sample" ]; do
    sleep 3;
    echo -n "."
done
echo ""


# Enable reverse proxy for nextcloud:
mv $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf.sample \
   $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf
docker-compose restart swag

echo -n "Waiting for nextcloud to perform initial configuration." | ww
while [ ! -f "$NC_CONF" ]; do
    sleep 5
    echo -n "."
    # Load nextcloud to let nextcloud generate the initial config-files
    curl -s https://$domain/nextcloud
done
echo ""
sleep 5


# Adjust nextcloud settings:
grep -v "^$" $NC_CONF | head -n -1 > tmp.conf
echo "  'trusted_proxies' => ['swag']," >> tmp.conf
echo "  'overwritewebroot' => '/nextcloud'," >> tmp.conf
echo "  'overwrite.cli.url' => 'https://$domain/nextcloud'" >> tmp.conf
grep -v "^$" $NC_CONF | tail -n 1 >> tmp.conf
mv tmp.conf $NC_CONF
chown $uid:$gid $NC_CONF


echo "Configuration complete, stopping server." | ww
docker-compose down
echo "The database passwords have been generated automatically. You can find them in the './.env'-file." | ww
