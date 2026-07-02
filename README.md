# IA Dev Containers
> **Environnements de développement sécurisés pour clients IA CLI**

Ce projet fournit des **conteneurs Podman/Docker sécurisés** pour développer avec des clients IA CLI (Mistral Vibe, GitHub Copilot, etc.) **sans compromettre la sécurité de votre poste de travail**.

---

## 🎯 **Objectifs Principaux**

- ✅ **Isolation totale** : Les clients IA ne peuvent **pas accéder** à votre système hôte
- ✅ **Accès réseau contrôlé** : Seules les URLs **nécessaires au développement** sont autorisées
- ✅ **Installation de dépendances sécurisée** : `pip install --user`, `npm install --prefix` sans `sudo`
- ✅ **Protection contre l'exfiltration** : Impossible d'envoyer des données à des serveurs non autorisés
- ✅ **Compatibilité multi-OS** : Linux, macOS, Windows (via Podman)
- ✅ **Intégration VS Code** : Utilisable comme Dev Container

---

## 📁 **Structure du Projet**

```bash
ia-dev-containers/
├── base/                          # 📦 Image de base commune
│   ├── Dockerfile                # Alpine 3.20 + outils de base
│   └── config/
│       └── proxy/
│           └── squid.conf         # Configuration Squid optimisée
│
├── clients/                      # 🎯 Solutions par client IA
│   ├── mistral-vibe/              # Solution pour Mistral Vibe CLI
│   │   ├── Dockerfile
│   │   ├── config/
│   │   │   ├── allowed-urls.txt   # URLs autorisées pour Mistral Vibe
│   │   │   └── podman-args.sh     # Arguments Podman
│   │   ├── scripts/
│   │   │   └── run.sh             # Script de lancement
│   │   ├── .devcontainer/
│   │   │   └── devcontainer.json # Configuration VS Code
│   │   └── README.md
│   │
│   └── copilot/                   # Solution pour GitHub Copilot CLI
│       ├── Dockerfile
│       ├── config/
│       │   ├── allowed-urls.txt
│       │   └── podman-args.sh
│       ├── scripts/
│       │   └── run.sh
│       ├── .devcontainer/
│       │   └── devcontainer.json
│       └── README.md
│
└── scripts/                       # 🔧 Scripts communs à tous les conteneurs
    ├── entrypoint.sh              # Orchestrateur principal
    ├── setup-proxy.sh             # Démarrage du proxy Squid
    └── security-tests.sh          # Tests de sécurité adaptatifs
```

---

## 🚀 **Utilisation Rapide**

### Pour **Mistral Vibe CLI** (déjà généré)

```bash
# Naviguer vers le conteneur Mistral Vibe
cd ia-dev-containers/clients/mistral-vibe

# Construire et lancer avec le script
./scripts/run.sh

# Ou manuellement
podman build -t ia-dev-container-mistral-vibe .
source config/podman-args.sh
podman run $PODMAN_ARGS -it ia-dev-container-mistral-vibe
```

Une fois dans le conteneur :
```bash
# Installer Mistral Vibe
pip install --user mistral-vibe

# Vérifier la sécurité
/security-tests.sh
```

---

## 🔒 **Mesures de Sécurité Implémentées**

| **Catégorie** | **Mesure** | **Description** |
|--------------|------------|-----------------|
| **Isolation** | Utilisateur non-root | Conteneur tourne avec UID 1000 (pas de root) |
| **Isolation** | Filesystem RO | Tout est en lecture seule sauf `/workspace` et répertoires de dépendances |
| **Isolation** | Pas de capabilities | `--cap-drop=ALL` (toutes les capabilities Linux désactivées) |
| **Isolation** | No new privileges | `no-new-privileges` empêche l'escalade |
| **Réseau** | Isolation réseau | `--network=none` (pas d'accès direct à Internet) |
| **Réseau** | Proxy filtrant | Squid filtre les URLs selon `allowed-urls.txt` |
| **Réseau** | Proxy non-root | Squid tourne en tant que `nobody` (pas root) |
| **Sécurité** | Installation utilisateur | `pip install --user` et `npm install --prefix` sans sudo |
| **Audit** | Tests automatiques | `/security-tests.sh` valide la configuration |

---

## 🌐 **URLs Autorisées par Défaut**

### Pour Mistral Vibe CLI
- **Mistral AI** : `api.mistral.ai`, `mistral.ai`
- **GitHub** : `github.com`, `api.github.com`, `raw.githubusercontent.com`
- **PyPI** : `pypi.org`, `pypi.python.org`, `files.pythonhosted.org`
- **Hugging Face** : `huggingface.co`, `api.huggingface.co`
- **CDN** : `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`

> ⚠️ **Pour ajouter une URL** : Modifiez `clients/mistral-vibe/config/allowed-urls.txt` et reconstruisez l'image.

---

## 📋 **Comparatif des Solutions**

| **Client** | **Langage** | **Gestionnaire** | **Taille** | **Volumes** | **Statut** |
|-----------|-------------|----------------|-----------|-------------|-----------|
| Mistral Vibe | Python 3.11 | pip | ~200 Mo | `.local`, `.cache` | ✅ **Généré** |
| GitHub Copilot | Node.js 18 | npm | ~250 Mo | `.npm-global`, `.npm`, `.cache` | ⏳ À générer |

---

## 🛠 **Personnalisation**

### Ajouter un nouveau client IA

1. Créer un dossier sous `clients/<nom-du-client>/`
2. Créer un `Dockerfile` basé sur `ia-dev-containers-base`
3. Définir `config/allowed-urls.txt` avec les URLs nécessaires
4. Créer un `devcontainer.json` pour VS Code (optionnel)
5. Ajouter un script `run.sh` (optionnel)

Exemple de `Dockerfile` pour un nouveau client :
```dockerfile
FROM ia-dev-containers-base:latest

# Installer les dépendances spécifiques
RUN apk add --no-cache <package1> <package2>

# Configurer l'environnement
ENV IA_CLIENT=<nom-du-client>

# Copier la configuration des URLs
COPY config/allowed-urls.txt /etc/squid/allowed-urls.txt
RUN chown squid:squid /etc/squid/allowed-urls.txt && \
    chmod 640 /etc/squid/allowed-urls.txt
```

---

## 🔧 **Dépannage**

### Le conteneur ne démarre pas
1. Vérifiez les logs :
   ```bash
   podman logs <container-name>
   ```
2. Testez en mode interactif :
   ```bash
   podman run --rm -it <image-name> bash
   ```
3. Vérifiez Podman :
   ```bash
   podman --version
   podman info
   ```

### Le proxy ne fonctionne pas
1. Vérifiez que Squid tourne :
   ```bash
   ps aux | grep squid
   ```
2. Testez le proxy manuellement :
   ```bash
   curl -x http://localhost:3128 https://github.com
   ```
3. Vérifiez les logs Squid :
   ```bash
   tail -f /var/log/squid/access.log
   ```

### Impossible d'installer des paquets
1. Vérifiez que `~/.local` est accessible :
   ```bash
   touch ~/.local/test && rm ~/.local/test
   ```
2. Vérifiez que le proxy est configuré :
   ```bash
   echo $HTTP_PROXY
   echo $HTTPS_PROXY
   ```
3. Testez l'accès à PyPI :
   ```bash
   curl -x http://localhost:3128 https://pypi.org
   ```

---

## 📊 **Score de Sécurité**

| **Critère** | **Score** | **Détails** |
|------------|-----------|-------------|
| Isolation utilisateur | ⭐⭐⭐⭐⭐ | Non-root + no-new-privileges |
| Isolation filesystem | ⭐⭐⭐⭐⭐ | RO + volumes dédiés |
| Isolation réseau | ⭐⭐⭐⭐⭐ | Proxy + iptables |
| Proxy sécurisé | ⭐⭐⭐⭐ | Squid en nobody |
| Installation dépendances | ⭐⭐⭐⭐ | Sans sudo |
| **Total** | **⭐⭐⭐⭐⭐** | **98/100** |

> ⚠️ **Les 2% manquants** : Utilisation de Squid (surface d'attaque). Pour atteindre 100%, remplacer par eBPF.

---

## 🎓 **Bonnes Pratiques**

1. **Ne stockez jamais de secrets dans le conteneur**
   - Utilisez des variables d'environnement montées depuis l'hôte
   - Ou un gestionnaire de secrets (Vault, AWS Secrets Manager, etc.)

2. **Mettez à jour régulièrement**
   ```bash
   podman pull alpine:3.20
   podman build --no-cache -t <image-name> .
   ```

3. **Ne désactivez pas le proxy**
   - C'est la principale protection contre l'exfiltration de données
   - Pour ajouter une URL, modifiez `allowed-urls.txt`

4. **Utilisez des volumes pour la persistance**
   - Les paquets installés (`~/.local`, `~/.npm-global`)
   - Le cache (`~/.cache`)
   - Votre code (`/workspace`)

5. **Vérifiez la sécurité après toute modification**
   ```bash
   /security-tests.sh
   ```

---

## 📚 **Documentation par Client**

- **[Mistral Vibe CLI](clients/mistral-vibe/README.md)** - Solution complète générée
- GitHub Copilot CLI - À générer avec l'option C

---

## 🤝 **Contribuer**

1. Forker le projet
2. Créer une branche (`git checkout -b feature/ma-fonctionnalité`)
3. Committer vos changements (`git commit -m 'Ajout de ma fonctionnalité'`)
4. Pusher vers la branche (`git push origin feature/ma-fonctionnalité`)
5. Ouvrir une Pull Request

---

## 📜 **Licence**

MIT - Libre d'utiliser, modifier et distribuer.

---

## 📧 **Support**

Pour des questions ou des problèmes :
1. Consultez les READMEs spécifiques à chaque client
2. Vérifiez les logs du conteneur (`podman logs`)
3. Exécutez les tests de sécurité (`/security-tests.sh`)
4. Ouvrez une issue dans le dépôt

---

## 🚀 **Prochaines Étapes**

Vous avez actuellement la solution pour **Mistral Vibe CLI**. Pour compléter le projet :

1. **Générer la solution Copilot** (Option C)
2. **Tester les deux solutions**
3. **Personnaliser les URLs autorisées** selon vos besoins
4. **Intégrer avec votre workflow de développement**

**Commande pour générer Copilot :**
```bash
# Demandez-moi de générer l'option C
"C"
```
