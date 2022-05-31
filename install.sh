#!/bin/bash

LINE_WIDTH=60
function ww() {
    cat | fold -s -w $LINE_WIDTH
}
function pw() {
    head -c $1 /dev/urandom | base64 -w 0 | sed 's#/##g' | head -c $1
}

echo -n "Please enter the base directory in which all bind-mounts will be placed: ($(pwd))" | ww
read BASE_DIR
if [ -z $BASE_DIR ]; then
    BASE_DIR=$(pwd)
fi

if [ -d $BASE_DIR/mariadb ] || [ -d $BASE_DIR/nextcloud ]; then
    echo "Script should only be used for first installation, but either nextcloud or mariadb seem to be already set up." | ww
    echo "Aborting."
    exit 1
fi

mkdir -p $BASE_DIR && cd $BASE_DIR
if [ -d .git ]; then
    echo "$BASE_DIR already contains a git repository. You should only continue, if this is the correct repository and working-tree." | ww
    echo -n "Continue? [yN] "
    read answer
    if [ $answer != "Y" ] && [ $answer != "y" ]; then
        exit 0;
    fi
else
    git clone https://github.com/xwst/home-server.git .
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
mkdir -p $BASE_DIR/gitea/config $BASE_DIR/gitea/data
chown -R $uid:$gid $BASE_DIR


echo "Please enter a single domain under which the server is accessible. Additional domains need to be configured manually later." | ww
echo -n "Domain: "
read domain;

echo "Creating environment file for docker-compose. Timezone is copied from host!" | ww
echo "BASE_DIR=$BASE_DIR" > .env
echo -en "PUID=$uid\nPGID=$gid\nMYDOMAIN=$domain\nTIMEZONE=" >> .env
cat /etc/timezone >> .env
chmod 600 .env
DB_ROOT_PW=$(pw 20)
GITEA_DB_PASSWORD=$(pw 20)
echo "DB_ROOT_PW=$DB_ROOT_PW" >> .env
echo "DB_NEXTCLOUD_PW=$(pw 20)" >> .env
echo "COLLABORA_ADMIN_PW=$(pw 20)" >> .env
echo "GITEA_DB_PASSWORD=$GITEA_DB_PASSWORD" >> .env

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

# Enable reverse proxies:
mv $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf.sample \
   $BASE_DIR/swag/nginx/proxy-confs/nextcloud.subfolder.conf
cp $BASE_DIR/collabora.subfolder.conf \
   $BASE_DIR/swag/nginx/proxy-confs/
mv $BASE_DIR/swag/nginx/proxy-confs/gitea.subfolder.conf.sample \
   $BASE_DIR/swag/nginx/proxy-confs/gitea.subfolder.conf
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

# Setup databases
SQL_SCRIPT=$(sed "s/%GITEA_DB_PASSWORD%/$GITEA_DB_PASSWORD/" setup_db.sql)
docker exec -it mariadb /bin/bash -c "echo \"$SQL_SCRIPT\" | mysql -u root -p\"$DB_ROOT_PW\""


# Adjust nextcloud settings:
grep -v "^$" $NC_CONF | head -n -1 > tmp.conf
echo "  'trusted_proxies' => ['swag']," >> tmp.conf
echo "  'overwritewebroot' => '/nextcloud'," >> tmp.conf
echo "  'overwrite.cli.url' => 'https://$domain/nextcloud'" >> tmp.conf
grep -v "^$" $NC_CONF | tail -n 1 >> tmp.conf
mv tmp.conf $NC_CONF
chown $uid:$gid $NC_CONF

# Adjust gitea settings:
sed -i -e "s#\[server\]#[server]\nROOT_URL                = https://$domain/gitea/\nDOMAIN                  = $domain#" \
    -e 's/\(START_SSH_SERVER.*= \).*/\1false/' \
    -e 's/\(DISABLE_SSH.*= \).*/\1true/' \
    $BASE_DIR/gitea/conf/app.ini


echo "Configuration complete, stopping server." | ww
docker-compose down
echo "Various passwords have been generated automatically. You can find them in the './.env'-file. You may now start the services using docker-compose. Do not forget to configure the ddclient by editing $BASE_DIR/ddclient/ddclient.conf." | ww
