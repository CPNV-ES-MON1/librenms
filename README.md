# Déploiement du Script

Script d'installation LibreNMS
Le script contient toute l'installation à partir d'une machine vierge ayant Ubuntu 24.04.

Pour lancer le script 
Donner les droits au fichier du script :
```
sudo chmod +x "NomDuFichier.sh"
```

Lancement du script
```
sudo bash "NomDuFichier.sh" --db-pass "Pa$$w0rd" --admin-user "cpnv" --admin-pass "Pa$$w0rd"
```
Arguments obligatoires :
- --db-pass Mot de passe de l'utilisateur MariaDB
- --admin-user Nom d'utilisateur administrateur LibreNMS
- --admin-pass Mot de passe administrateur LibreNMS

Ce que fait le script automatiquement

- Formate et monte sdb sur /data et y installe LibreNMS via un lien symbolique /opt/librenms → /data/librenms
- Installe et configure tous les composants (PHP 8.3, Nginx, MariaDB, SNMP, rrdcached)
- Crée la base de données et l'utilisateur
- Déploie LibreNMS et crée le compte administrateur
- Ajoute la machine locale comme device et lance la première collecte de métriques

À la fin du script, LibreNMS est accessible via http://<IP_DE_LA_MACHINE>

