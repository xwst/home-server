#!/bin/bash

LINE_WIDTH=60

echo -n "Please enter the base directory in which all bind-mounts will be placed: ($(pwd))" | fold -s -w $LINE_WIDTH
read BASE_DIR
if [ -z $BASE_DIR ]; then
    BASE_DIR=$(pwd)
fi

echo "The linuxserver.io-images require a user that will be the owner of the bind-mounted data within the docker containers. If you give a user name that does not exist, a new one will be created." | fold -s -w $LINE_WIDTH
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


echo "Please enter a single domain under which the server is accessible. Additional domains need to be configured manually later." | fold -s -w $LINE_WIDTH
echo -n "Domain: "
read domain;

echo "Creating environment file for docker-compose. Timezone is copied from host!" | fold -s -w $LINE_WIDTH
echo "BASE_DIR=$BASE_DIR" >> .env
echo -en "PUID=$uid\nPGID=$gid\nMYDOMAIN=$domain\nTIMEZONE=" >> .env
cat /etc/timezone >> .env
chmod 600 ./env

echo "Starting server to continue with configuration." | fold -s -w $LINE_WIDTH
docker-compose up -d

mv $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf.sample \
   $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf
CONF=$BASE_DIR/nextcloud/config/www/nextcloud/config/config.php 
head -n -1 $CONF > tmp.conf
echo "  'trusted_proxies' => ['swag']," >> tmp.conf
echo "  'overwritewebroot' => '/nextcloud'," >> tmp.conf
echo "  'overwrite.cli.url' => 'https://$domain/nextcloud'" >> tmp.conf
tail -n 1 $CONF >> tmp.conf
mv tmp.conf $CONF


echo "Configuration complete, stopping server." | fold -s -w $LINE_WIDTH
docker-compose down

