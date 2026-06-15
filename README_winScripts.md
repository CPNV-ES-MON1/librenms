Déploiement du Script
Script d'installation et de configuration du client Windows.

Tout d'abbord il faut executer le script .ps1 sur le client Windows pour préparer le client avec ses règles firewall et les services nécessaires :

.\setup-win-librenms.ps1 -LibreNMSIP "IP du serveur LibreNMS" -SNMPCommunity public

Ensuite il faut executer le script sur le serveur LibreNMS :
Pour lancer le script Donner les droits au fichier du script :

sudo chmod +x "NomDuFichier.sh"
Lancement du script

sudo bash setup-win-librenms.sh \
  --win-ip "IP du client Windows" \
  --win-password 'Mot de passe du client Windows' \
  --mysql-password 'Mot de passe mysql'
Arguments obligatoires :

Ce script va permettre de mettre en place les différentes règles firewall, l'installation de l'agent, le redémmarage d'un service automatiquement et d'ajouter le client sur LibreNMS.
