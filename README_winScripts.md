Déploiement du Script
Script d'installation et de configuration du client Windows.

Installer git pour cloner le dêpot via powershell :
```
winget install --id Git.Git -e --source winget
```
Clôner le dêpot ensuite via le cmd git et prendre la branch develop :
```
git clone https://github.com/CPNV-ES-MON1/librenms.git
git checkout -b develop origin/develop
```
Tout d'abbord il faut executer le script .ps1 sur le client Windows pour préparer le client avec ses règles firewall et les services nécessaires :
```
.\setup-win-librenms.ps1 -LibreNMSIP "IP du serveur LibreNMS" -SNMPCommunity public
```
Ensuite il faut executer le script sur le serveur LibreNMS :
Pour lancer le script Donner les droits au fichier du script :
```
sudo chmod +x "NomDuFichier.sh"
```
Avant d'executer le script il faut faire cette commande sur le serveur :
```
sudo apt update && sudo apt install -y sshpass
```

Lancement du script
```
sudo bash setup-win-librenms.sh \
  --win-ip "IP du client Windows" \
  --win-password 'Mot de passe du client Windows' \
  --mysql-password 'Mot de passe mysql'
  ```
Installer ensuite le plugin Nagios et faites un pool sur les clients :
```
sudo apt update && sudo apt install -y nagios-plugins-basic nagios-plugins-standard
sudo -u librenms php /opt/librenms/check-services.php -d
```

Ce script va permettre de mettre en place les différentes règles firewall, l'installation de l'agent, le redémmarage d'un service automatiquement et d'ajouter le client sur LibreNMS.
