Déploiement du Script
Script d'installation et de configuration du client Linux.

Installer git pour cloner le dêpot via powershell :
```
sudo apt install -y git

```
Clôner le dêpot ensuite via le cmd git et prendre la branch develop :
```
git clone https://github.com/CPNV-ES-MON1/librenms.git
git checkout -b develop origin/develop
```
Tout d'abbord il faut executer le script .sh sur le client Linux pour préparer le client avec ses règles firewall et les services nécessaires mais il faut égalemment d'abbord le rendre executable:
```
sudo chmod +x "NomDuFichier.sh"
sudo bash setup-lin-client.sh --librenms-ip 10.0.2.10 --snmp-community public
```
Créer un compte pour le lancement du script "CPNV" et lui donner des permissions :
```
sudo adduser cpnv
sudo passwd cpnv
sudo usermod -aG sudo cpnv
```

Ensuite il faut executer le script sur le serveur LibreNMS :
Pour lancer le script Donner les droits au fichier du script :
```
sudo chmod +x "NomDuFichier.sh"
```
Avant d'executer le script il faut faire cette commande sur le serveur :
```
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
```
Et être sûr que sshpass est bien installé :
```
sudo apt update && sudo apt install -y sshpass
```

Lancement du script
```
sudo bash setup-lin-librenms.sh --lin-ip "Ip client linux"   --lin-password 'MDP du compte CPNV linux'   --mysql-password 'MDP mysql'
  ```

Ce script va permettre de mettre en place les différentes règles firewall, l'installation de l'agent, le redémmarage d'un service automatiquement et d'ajouter le client sur LibreNMS.
