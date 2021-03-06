#!/bin/bash

set -e

INTERFACE="eth0"

# You need to be root, sorry.
if [[ $EUID -ne 0 ]]; then
	echo "This script requires elevated privileges to run. Are you root?"
	exit
fi

echo 'Create MySQL root password:'
read -s MYSQLROOTPASSWD
echo 'Create snorbyuser database password:'
read -s SNORBYDBPASS


DATE=$(date +"%Y%m%d%H%M")

#echo "Build rails (1/4) wgetting..."
#wget https://cache.ruby-lang.org/pub/ruby/2.2/ruby-2.2.6.tar.gz > /dev/null
#echo "Build rails (2/4) extracting..."
#tar xzf ruby-2.2.6.tar.gz > /dev/null
#echo "Build rails (3/4) configuring..."
#cd ruby-2.2.6
#./configure > /dev/null
#echo "Build rails (4/4) make and install..."
#make > /dev/null
#make install-conf > /dev/null

sudo apt-get install curl -y > /dev/null

gpg --keyserver hkp://pgp.mit.edu --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
curl -L https://get.rvm.io | bash
source /usr/local/rvm/scripts/rvm
echo "source /usr/local/rvm/scripts/rvm" >> /root/.bashrc
rvm install 2.2.3

echo "Snorby dependencies (1/3) apt-get dependencies..."
apt-get install wkhtmltopdf gcc g++ build-essential libssl-dev libreadline6-dev zlib1g-dev libsqlite3-dev libxslt-dev libxml2-dev imagemagick git-core libmysqlclient-dev libmagickwand-dev default-jre postgresql-server-dev-9.4 -y > /dev/null
echo "Snorby dependencies (2/3) MySQL server..."
debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQLROOTPASSWD"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQLROOTPASSWD"
sudo apt-get -y install mysql-server > /dev/null
echo "Snorby dependencies (3/3) gem dependencies..."

gem install thor i18n bundler tzinfo builder memcache-client rack rack-test erubis mail rack-mount rails sqlite3
echo "Done."
echo ""

echo "Installing Suricata (1/4) apt-getting..."
apt-get install suricata -y > /dev/null
cp /etc/suricata/suricata-debian.yaml /etc/suricata/suricata.yaml
echo "Installing Suricata (2/4) configuring /etc/default/suricata..."
sed -i "s#RUN=.*#RUN=yes#g" /etc/default/suricata
sed -i "s#LISTENMODE=.*#LISTENMODE=af-packet#g" /etc/default/suricata
sed -i "s#SURCONF=.*#SURCONF=/etc/suricata/suricata.yaml#g" /etc/default/suricata
echo "Installing Suricata (3/4) configuring /etc/suricata/suricata.yaml..."
#NOTE doesn't seem to run, but w/e, will deal with later
sed -i "s|windows: [0.0.0.0/0].*|#windows: [0.0.0.0/0]|g" /etc/suricata/suricata.yaml
perl -0777 -i -pe  "s/- unified2-alert:\s*enabled:.*/- unified2-alert:\n      enabled: yes/g" /etc/suricata/suricata.yaml
echo "Installing Suricata (4/4) getting rules..."
cd /etc/suricata/
wget -q http://rules.emergingthreats.net/open/suricata/emerging.rules.tar.gz > /dev/null
tar xzf emerging.rules.tar.gz
rm emerging.rules.tar.gz
echo "Done."
echo ""

echo "Snorby prepare (1/3) cloning..."
if [ -d "/var/www/snorby" ]; then
  mv /var/www/snorby /var/www/snorby.BAK.$DATE
fi
git clone http://github.com/Snorby/snorby.git /var/www/snorby > /dev/null 2>&1
echo "Snorby prepare (2/3) building configurations..."
cp /var/www/snorby/config/database.yml.example /var/www/snorby/config/database.yml
cp /var/www/snorby/config/snorby_config.yml.example /var/www/snorby/config/snorby_config.yml
sed -i "s/password: .*\$/password: $MYSQLROOTPASSWD/" /var/www/snorby/config/database.yml
sed -i "s/domain: .*\$/domain: 'localhost:3000'/" /var/www/snorby/config/snorby_config.yml
sed -i "s/wkhtmltopdf: .*\$/wkhtmltopdf: wkhtmltopdf/" /var/www/snorby/config/snorby_config.yml
echo "Snorby prepare (3/3) suricata rules..."
if grep -Fxq "/etc/suricata/rules/" /var/www/snorby/config/snorby_config.yml
then
  echo "Rules already in snorby config."
else
  sed -i "s#rules:#rules: \n    - \"/etc/suricata/rules/\"#g" /var/www/snorby/config/snorby_config.yml
fi
echo "Done."
echo ""

echo "Snorby setup (1/6) updating snorby configuration and getting dependencies..."
cd /var/www/snorby && bundle update activesupport railties rails > /dev/null
echo "Snorby setup (2/6) installing dependencies..."
gem install arel ezprint > /dev/null
echo "Snorby setup (3/6) bundle installing..."
bundle install > /dev/null
echo "Snorby setup (4/6) setting up Snorby..."
bundle exec rake snorby:setup RAILS_ENV=production > /dev/null || \
( echo "Snorby setup failed due to error. Attempting patch for later versions of MySQL..." \
&& sed -i 's/do_mysql (~> 0.10.6)/do_mysql (~> 0.10.17)/' /var/www/snorby/Gemfile.lock \
&& sed -i 's/do_mysql (0.10.16)/do_mysql (0.10.17)/' /var/www/snorby/Gemfile.lock \
&& bundle install > /dev/null \
&& bundle exec rake snorby:setup RAILS_ENV=production > /dev/null )

echo "Snorby setup (5/6) creating MySQL User for snorby..."
mysql -u root --password=$MYSQLROOTPASSWD -e "GRANT ALL PRIVILEGES ON snorby.* TO 'snorbyuser'@'localhost' IDENTIFIED BY '$SNORBYDBPASS' with grant option;"
#mysql -u root --password=$MYSQLROOTPASSWD -e "grant all privileges on snorby.* to 'snorbyuser'@'localhost' with grant option;"
mysql -u root --password=$MYSQLROOTPASSWD -e "flush privileges;"

echo "Snorby setup (6/6) correcting snorby database config with new user..."
sed -i "s/password: .*\$/password: $SNORBYDBPASS/" /var/www/snorby/config/database.yml
sed -i "s/username: .*\$/username: snorbyuser/" /var/www/snorby/config/database.yml
echo "Done."
echo ""

echo "Configuring MySQL listen..."
sed -i 's/bind-address\s\+.*/bind-address = 0.0.0.0/g' /etc/mysql/my.cnf
service mysql restart
echo ""

echo "Installing Apache2 (1/5) apt-getting..."
apt-get install apache2 apache2-dev libapr1-dev libaprutil1-dev libcurl4-openssl-dev -y > /dev/null
service apache2 start
echo "Installing Apache2 (2/5) fixing permissions..."
chown www-data:www-data /var/www/snorby -R

echo "Installing Apache2 (3/5) writing new apache config..."
cat <<EOT >> /etc/apache2/sites-available/snorby.conf
<VirtualHost *:80>
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/snorby/public

        <Directory "/var/www/snorby/public">
                AllowOverride all
                Order deny,allow
                Allow from all
                Options -MultiViews
        </Directory>

</VirtualHost>
EOT
echo "Installing Apache2 (4/5) enabling site..."
a2dissite 000-default.conf > /dev/null 2>&1
a2ensite snorby.conf > /dev/null 2>&1
echo "Installing Apache2 (5/5) starting Apache..."
service apache2 restart
echo "Done"
echo ""

echo "Passenger (1/4) installing Passenger gem..."
gem install --no-ri --no-rdoc passenger > /dev/null
echo "Passenger (2/4) installing Passenger module..."
#/usr/local/bin/passenger-install-apache2-module -a 2> /tmp/.passenger_error.txt 1> /tmp/.passenger_compile_out \
#|| ( echo "Encountered error installing Passenger:" && cat /tmp/.passenger_error.txt )
#sed -n '/LoadModule passenger_module \/var\//,/<\/IfModule>/p' /tmp/.passenger_compile_out > /etc/apache2/mods-available/passenger.load
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
apt-get install -y apt-transport-https ca-certificates
#TODO: check that repo doesn't exist
sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger trusty main > /etc/apt/sources.list.d/passenger.list'
apt-get update > /dev/null
sudo apt-get install -y libapache2-mod-passenger

echo "Passenger (3/4) creating Passenger module configuration..."
a2enmod passenger > /dev/null
a2enmod rewrite > /dev/null
a2enmod ssl > /dev/null
echo "Passenger (4/4) restarting Apache..."
service apache2 restart > /dev/null
echo "Done."
echo ""


cd /var/www/snorby
echo "Snorby install (1/2) bundle packing snorby..."
bundle pack > /dev/null
echo "Snorby install (2/2) installing..."
bundle install --path vender/cache > /dev/null
echo "Done."
echo ""


by2steps=19
echo "Installing Barnyard2 (1/$by2steps) install apt dependencies..."
apt-get install libpcre3 libpcre3-dbg libpcre3-dev build-essential autoconf automake libtool libpcap-dev libnet1-dev libyaml-0-2 libyaml-dev zlib1g zlib1g-dev libcap-ng-dev libcap-ng0 make libmagic-dev git pkg-config libnss3-dev libnspr4-dev wget mysql-client libmysqlclient-dev libdumbnet-dev -y > /dev/null
apt-get install libmysqlclient20 -y > /dev/null || (echo "Switching to 18..." && apt-get install libmysqlclient18 -y > /dev/null)

cd /tmp
echo "Installing Barnyard2 (2/$by2steps) getting OISF source..."
if [ -d "/tmp/oisf" ]; then
  rm -r /tmp/oisf
fi
git clone -q git://phalanx.openinfosecfoundation.org/oisf.git > /dev/null
cd oisf
echo "Installing Barnyard2 (3/$by2steps) getting libhtp..."
git clone -q https://github.com/OISF/libhtp.git > /dev/null
echo "Installing Barnyard2 (4/$by2steps) generating for oisf..."
./autogen.sh > /dev/null 2>&1
echo "Installing Barnyard2 (5/$by2steps) configuring oisf..."
./configure --with-libnss-libraries=/usr/lib --with-libnss-includes=/usr/include/nss/ --with-libnspr-libraries=/usr/lib --with-libnspr-includes=/usr/include/nspr > /dev/null
echo "Installing Barnyard2 (6/$by2steps) making oisf..."
make > /dev/null
echo "Installing Barnyard2 (7/$by2steps) installing oisf..."
make install-full > /dev/null
ldconfig

echo "Installing Barnyard2 (8/$by2steps) installing DAQ dependencies..."
apt-get install flex bison -y > /dev/null
cd /tmp
echo "Installing Barnyard2 (9/$by2steps) getting daq-2.0.6 source..."
wget -q https://www.snort.org/downloads/snort/daq-2.0.6.tar.gz > /dev/null
if [ -d "/tmp/daq-2.0.6" ]; then
  rm -r /tmp/daq-2.0.6
fi
tar xzf daq-2.0.6.tar.gz
cd daq-2.0.6
echo "Installing Barnyard2 (10/$by2steps) configuring daq-2.0.6..."
./configure > /dev/null 2>&1
echo "Installing Barnyard2 (11/$by2steps) compiling daq-206..."
make > /dev/null 2>&1
echo "Installing Barnyard2 (12/$by2steps) installing daq..."
make install > /dev/null

echo "Installing Barnyard2 (13/$by2steps) gitting Barnyard2..."
cd /tmp
if [ -d "/tmp/barnyard2" ]; then
  rm -r /tmp/barnyard2
fi
git clone https://github.com/firnsy/barnyard2 > /dev/null 2>&1
cd barnyard2
echo "Installing Barnyard2 (14/$by2steps) generating for Barnyard2..."
./autogen.sh > /dev/null 2>&1
echo "Installing Barnyard2 (15/$by2steps) configuring Barnyard2..."
autoreconf --force --install > /dev/null
./configure --with-mysql --with-mysql-libraries=/usr/lib/x86_64-linux-gnu/ > /dev/null
if [ -f /usr/include/dnet.h ];
then
   rm /usr/include/dnet.h
fi
echo "Installing Barnyard2 (16/$by2steps) linking limbumdnet..."
ln -s /usr/include/dumbnet.h /usr/include/dnet.h
echo "Installing Barnyard2 (17/$by2steps) compiling Barnyard2, suppressing warnings..."
make > /dev/null 2>&1
echo "Installing Barnyard2 (18/$by2steps) installing Barnyard2..."
make install > /dev/null
cp /tmp/barnyard2/etc/barnyard2.conf /etc/suricata/
echo "Installing Barnyard2 (19/$by2steps) configuring /etc/suricata/barnyard2.conf..."
sed -i "s/#config interface:\s\+$INTERFACE/config interface:  $INTERFACE/g" /etc/suricata/barnyard2.conf
sed -i "s/#config daemon/config daemon/g" /etc/suricata/barnyard2.conf
sed -i "s/#config verbose/config verbose/g" /etc/suricata/barnyard2.conf
sed -i "s;#config waldo_file:.*;config waldo_file: /var/log/suricata/suricata.waldo;" /etc/suricata/barnyard2.conf
sed -i "s#config reference_file:\s\+/etc/.*#config reference_file:      /etc/suricata/reference.config#g" /etc/suricata/barnyard2.conf
sed -i "s#config classification_file:\s\+/etc/.*#config classification_file: /etc/suricata/classification.config#g" /etc/suricata/barnyard2.conf
sed -i "s#config gen_file:\s\+/etc/.*#config gen_file:            /etc/suricata/rules/gen-msg.map#g" /etc/suricata/barnyard2.conf
sed -i "s#config sid_file:\s\+/etc/.*#config sid_file:            /etc/suricata/rules/sid-msg.map#g" /etc/suricata/barnyard2.conf

if grep -Fxq "user=snorbyuser" /etc/suricata/barnyard2.conf
then
  echo "Output database already configured."
else
  echo "output database: log, mysql, user=snorbyuser password=$SNORBYDBPASS dbname=snorby host=localhost sensor_name=sensor1" >> /etc/suricata/barnyard2.conf
fi

if [ ! -d "/var/log/barnyard2" ]; then
  mkdir /var/log/barnyard2
fi

service suricata stop
suricata -c /etc/suricata/suricata.yaml -i $INTERFACE -D > /dev/null || echo "Error starting Suricata, probably already running. Continuing."
barnyard2 -c /etc/suricata/barnyard2.conf -d /var/log/suricata -f unified2.alert -w /var/log/suricata/suricata.waldo -D || true

echo "Writing barnyard init.d..."
cat << 'EOT' >> /etc/init.d/barnyard2
#!/bin/sh
case $1 in
    start)
        echo "starting $0..."
        sudo barnyard2 -c /etc/suricata/barnyard2.conf -d /var/log/suricata -f unified2.alert -w /var/log/suricata/suricata.waldo
        echo -e 'done.'
    ;;
    stop)
        echo "stopping $0..."
        killall barnyard2
        echo -e 'done.'
    ;;
    restart)
        $0 stop
        $0 start
    ;;
    *)
        echo "usage: $0 (start|stop|restart)"
    ;;
esac

EOT

chmod 700 /etc/init.d/barnyard2
update-rc.d barnyard2 defaults 21 00

echo "Final Snorby config (1/2) soft reset..."
cd /var/www/snorby
bundle exec rake snorby:update RAILS_ENV=production > /dev/null
echo "Final Snorby config (2/2) fixing start on boot..."
sed -i 's#^exit.*#cd /var/www/snorby \&\& bundle exec rake snorby:update RAILS_ENV=production\n&#' /etc/rc.local
echo "Done."
echo ""

echo "---FINISHED---"
echo ""

exit 0;
