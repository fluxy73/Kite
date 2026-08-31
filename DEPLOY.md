# Déploiement — Kite sur un VPS Linux

Ce guide explique comment mettre le serveur Go de Kite en production sur un VPS Linux
(Ubuntu/Debian, ou WSL avec systemd) :

1. construire le binaire serveur ;
2. le faire tourner en permanence derrière **systemd** ;
3. l'exposer sur Internet via un **tunnel Cloudflare** (sans ouvrir de port, HTTPS inclus) ;
4. connecter l'app Flutter à distance avec le flag `KITE_API`.

Le serveur écoute sur `:8080` par défaut (`KITE_ADDR`, voir `server/main.go`) et persiste
ses données dans `data/kite.json` (`KITE_DATA`). Il expose aussi le WebSocket
`/api/ws` et le repli SSE `/api/events` — qui passent par le tunnel sans configuration
supplémentaire.

---

## 1. Construire le serveur

Sur la machine de déploiement (ou en cross-compile depuis le poste de dev) :

```bash
cd server
go build -o kite-server .
# Vérification rapide, en local :
KITE_ADDR=:8080 ./kite-server &
curl -s http://localhost:8080/api/health
kill %1
```

Installez le binaire et l'arborescence :

```bash
sudo mkdir -p /opt/kite/server/data
sudo cp kite-server /opt/kite/server/
sudo useradd --system --home /opt/kite --shell /usr/sbin/nologin kite 2>/dev/null || true
sudo chown -R kite:kite /opt/kite
```

---

## 2. Service systemd pour le serveur Go

Créez `/etc/systemd/system/kite.service` :

```ini
[Unit]
Description=Kite server (Go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kite
WorkingDirectory=/opt/kite/server
ExecStart=/opt/kite/server/kite-server
Environment=KITE_ADDR=:8080
Environment=KITE_DATA=/opt/kite/server/data/kite.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Activez-le et démarrez-le :

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kite
systemctl status kite --no-pager -l
```

Vérifiez en local :

```bash
curl -s http://localhost:8080/api/health
# → {"status":"ok"} (ou équivalent)
```

---

## 3. Tunnel Cloudflare (mode « tunnel nommé »)

Aucune porte n'est ouverte sur le pare-feu : c'est `cloudflared` qui ouvre la connexion
sortante vers Cloudflare et route `https://votre-domaine` vers `http://localhost:8080`.

### 3.1. Installer `cloudflared`

```bash
# x86_64 (Debian/Ubuntu) :
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
sudo install cloudflared /usr/local/bin/cloudflared
cloudflared --version
```

### 3.2. Créer le tunnel

```bash
cloudflared tunnel login        # ouvre le navigateur : autorisez le domaine
cloudflared tunnel create kite  # → crée ~/.cloudflared/<UUID>.json
cloudflared tunnel list         # notez l'UUID
```

### 3.3. Configurer le tunnel

Copiez le fichier de credentials et créez `/etc/cloudflared/config.yml` **complet**
(important : un `config.yml` vide fait échouer le service) :

```bash
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/<UUID>.json /etc/cloudflared/
```

```yaml
# /etc/cloudflared/config.yml
tunnel: <UUID>
credentials-file: /etc/cloudflared/<UUID>.json

ingress:
  - hostname: kite.votre-domaine.com
    service: http://localhost:8080
  - service: http_status:404
```

> Remplacez `<UUID>` par l'identifiant réel du tunnel (celui du `tunnel list`,
> aussi présent dans le nom du fichier `.json`).

### 3.4. Router le DNS

```bash
cloudflared tunnel route dns kite kite.votre-domaine.com
```

### 3.5. Installer et démarrer le service `cloudflared`

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
systemctl status cloudflared --no-pager -l
```

> Si le service est **déjà installé** (erreur « cloudflared service is already
> installed »), ne réinstallez pas : écrivez/mettez à jour la config puis
> `sudo systemctl restart cloudflared`.

---

## 4. Valider

```bash
curl -s https://kite.votre-domaine.com/api/health
# → même réponse que localhost

# WebSocket (doit répondre 101) :
curl -s -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://kite.votre-domaine.com/api/ws?userId=u1 | head -1
```

---

## 5. Connecter l'app Flutter à distance

```bash
cd app
flutter run --dart-define=KITE_API=https://kite.votre-domaine.com
```

Sur un émulateur Android, utilisez l'URL du tunnel de la même façon (elle est
accessible depuis l'émulateur, contrairement à `localhost` de l'hôte).

---

## 6. Mettre à jour le serveur

```bash
cd server && go build -o kite-server .
sudo systemctl stop kite
sudo cp kite-server /opt/kite/server/
sudo systemctl start kite
journalctl -u kite -n 20 --no-pager
```

---

## 7. Dépannage

| Symptôme | Cause / remède |
|---|---|
| `ERR Configuration file /etc/cloudflared/config.yml was empty` | Le fichier était vide lors de l'install. Écrivez la config complète (étape 3.3) puis `sudo systemctl restart cloudflared`. |
| `cloudflared service is already installed` | Le service existe déjà. Ne lancez pas `service install` à nouveau : mettez à jour `config.yml` puis `sudo systemctl restart cloudflared`. |
| `curl https://…` ne répond pas | `systemctl status cloudflared` ; vérifiez l'UUID dans `config.yml`, que le `.json` est bien dans `/etc/cloudflared/`, et que le DNS pointe sur le tunnel (`cloudflared tunnel route dns`). |
| `502/503 Bad Gateway` côté Cloudflare | Le serveur Go ne tourne pas : `systemctl status kite`, `curl -s localhost:8080/api/health`. |
| Test rapide sans domaine | Tunnel jetable : `cloudflared tunnel --url http://localhost:8080` (URL `trycloudflare.com`, non persistant). |

---

## 8. Notes

- **Ports** : seul `cloudflared` sort vers Cloudflare (443/7844). Le serveur Go reste
  sur `localhost` — ne l'exposez **pas** en `:0.0.0.0` sans pare-feu.
- **CORS** : le serveur accepte déjà les origines de l'app ; aucune config tunnel
  particulière pour le WebSocket `/api/ws`.
- **Sauvegarde** : le state vit dans `/opt/kite/server/data/kite.json` — sauvegardez
  ce fichier (et le `<UUID>.json` de `/etc/cloudflared/` pour recréer le tunnel).
- **Variante « token dashboard »** : si le tunnel est géré depuis le dashboard
  Cloudflare (pas de `config.yml`), installez le service directement avec le token :
  `sudo cloudflared service install <TOKEN>` — la config vit alors chez Cloudflare.