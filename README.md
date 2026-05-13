Direct install on Debian
```
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh | sudo bash
```

Pre-verifiable version
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh
less installRnsd_apt.sh
sudo bash installRnsd_apt.sh
```

Direct install on Alpine
```
wget -qO- https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh | sh
```

Pre-verifiable version
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh
cat installRnsd_apk.sh
chmod +x installRnsd_apk.sh
./installRnsd_apk.sh
```
