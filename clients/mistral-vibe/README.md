# Mistral Vibe CLI - Conteneur de Développement Sécurisé

> **Environnement isolé et sécurisé pour développer avec Mistral Vibe CLI**

---

## 🎯 **Objectifs**

Ce conteneur permet d'utiliser **Mistral Vibe CLI** dans un environnement **complètement isolé** de votre système hôte, avec :

- ✅ **Isolation totale** : Le client IA ne peut pas accéder à vos fichiers système
- ✅ **Accès réseau contrôlé** : Seules les URLs nécessaires sont autorisées (GitHub, PyPI, Mistral API)
- ✅ **Installation de dépendances sécurisée** : `pip install --user` fonctionne sans `sudo`
- ✅ **Protection contre l'exfiltration** : Impossible d'envoyer des données à des serveurs non autorisés
- ✅ **Compatibilité multi-OS** : Linux, macOS, Windows (via Podman)
- ✅ **Intégration VS Code** : Utilisable comme Dev Container

---

## 📁 **Structure**

```bash
clients/mistral-vibe/
├── Dockerfile              # Image Docker (Python 3.11 + dépendances)
├── config/
│   ├── allowed-urls.txt    # Liste des URLs autorisées
│   └── podman-args.sh      # Arguments Podman par défaut
├── scripts/
│   └── run.sh              # Script de lancement
└── .devcontainer/
    └── devcontainer.json   # Configuration VS Code
```

---

## 🚀 **Utilisation**

### **Prérequis**

- [Podman](https://podman.io/) installé et fonctionnel
- Sur macOS/Windows : Podman Desktop en cours d'exécution

#### Installation de Podman

**Linux (Debian/Ubuntu)** :
```bash
sudo apt update && sudo apt install -y podman
```

**Linux (Fedora/RHEL)** :
```bash
sudo dnf install -y podman
```

**macOS** :
```bash
brew install podman
podman machine init
podman machine start
```

**Windows** :
- Télécharger [Podman Desktop](https://podman-desktop.io/)

---

### **Méthode 1 : Avec le script de lancement (Recommandé)**

```bash
# Depuis le répertoire clients/mistral-vibe/
cd ia-dev-containers/clients/mistral-vibe

# Construire et lancer le conteneur
./scripts/run.sh
```

Le script va :
1. Vérifier que Podman est installé
2. Construire l'image si nécessaire
3. Lancer le conteneur avec la configuration sécurisée

---

### **Méthode 2 : En ligne de commande**

#### 1. Construire l'image

```bash
cd ia-dev-containers/clients/mistral-vibe
podman build -t ia-dev-container-mistral-vibe .
```

#### 2. Lancer le conteneur

```bash
# Avec les arguments par défaut (recommandé)
source config/podman-args.sh
podman run $PODMAN_ARGS -it ia-dev-container-mistral-vibe

# Ou en une seule commande
podman run \
  --user $(id -u):$(id -g) \
  --userns=keep-id \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --network=none \
  --read-only \
  --tmpfs=/tmp --tmpfs=/run \
  -v $(pwd)/../../../workspace:/workspace \
  -v mistral-vibe-local:/home/devuser/.local \
  -v mistral-vibe-cache:/home/devuser/.cache \
  -e HTTP_PROXY=http://localhost:3128 \
  -e HTTPS_PROXY=http://localhost:3128 \
  -e NO_PROXY=localhost,127.0.0.1 \
  -e IA_CLIENT=mistral-vibe \
  --rm --name mistral-vibe-dev \
  -it ia-dev-container-mistral-vibe
```

---

### **Méthode 3 : Avec VS Code (Recommandé pour le développement)**

1. Ouvrir le dossier `ia-dev-containers/clients/mistral-vibe` dans VS Code
2. Installer l'extension **[Remote - Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)**
3. Appuyer sur `F1` et sélectionner **"Remote-Containers: Reopen in Container"**
4. VS Code construira et démarrera automatiquement le conteneur

> ⚠️ **Sur macOS/Windows** : Assurez-vous que Podman Desktop est en cours d'exécution.

---

## 🔧 **Installation de Mistral Vibe CLI**

Une fois dans le conteneur, exécutez :

```bash
# Installer Mistral Vibe CLI
pip install --user mistral-vibe

# Mettre à jour (si nécessaire)
pip install --user --upgrade mistral-vibe

# Vérifier l'installation
mistral-vibe --version
```

> ✅ **Pas besoin de `sudo`** : L'installation se fait dans `~/.local` avec `--user`

---

## 📋 **Configuration de Sécurité**

### **Mesures implémentées**

| **Mesure** | **Description** | **Statut** |
|------------|-----------------|------------|
| 🔹 Utilisateur non-root | Conteneur tourne avec UID 1000 | ✅ |
| 🔹 Filesystem en lecture seule | Tout est en RO sauf `/workspace` et `~/.local` | ✅ |
| 🔹 Pas de capabilities | `--cap-drop=ALL` | ✅ |
| 🔹 No new privileges | Empêche l'escalade de privilèges | ✅ |
| 🔹 Réseau isolé | `--network=none` + proxy obligatoire | ✅ |
| 🔹 Proxy filtrant | Seules les URLs autorisées passent | ✅ |
| 🔹 Squid en nobody | Proxy ne tourne pas en root | ✅ |
| 🔹 Installation utilisateur | `pip install --user` sans sudo | ✅ |

---

### **URLs autorisées par défaut**

Le conteneur autorise l'accès à :

- **Mistral AI** : `api.mistral.ai`, `mistral.ai`
- **GitHub** : `github.com`, `api.github.com`, `raw.githubusercontent.com`
- **PyPI** : `pypi.org`, `pypi.python.org`, `files.pythonhosted.org`
- **Hugging Face** : `huggingface.co`, `api.huggingface.co`
- **CDN** : `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`

> ⚠️ **Pour ajouter une URL** :
> 1. Modifiez `config/allowed-urls.txt`
> 2. Reconstruisez l'image : `podman build -t ia-dev-container-mistral-vibe .`
> 3. Redémarrez le conteneur

---

## 🧪 **Vérifier la sécurité**

Dans le conteneur, exécutez :

```bash
/security-tests.sh
```

Exemple de sortie réussie :

```
╔══════════════════════════════════════════════════════════════════╗
║  Tests de Sécurité - Mistral Vibe CLI                        ║
╚══════════════════════════════════════════════════════════════════╝

🔒==== 1. Tests d'Isolation de l'Utilisateur ====🔒

✅ [PASS] Utilisateur non-root (UID=1000)
✅ [PASS] sudo nécessite un mot de passe (ou est bloqué)

📁==== 2. Tests d'Isolation du Système de Fichiers ====📁

✅ [PASS] / est en lecture seule
✅ [PASS] /usr est en lecture seule
✅ [PASS] /etc est en lecture seule
✅ [PASS] /workspace est accessible en écriture
✅ [PASS] ~/.local est accessible en écriture (pour pip)

🌐==== 3. Tests d'Isolation Réseau ====🌐

✅ [PASS] Accès direct à internet bloqué
✅ [PASS] Accès via proxy à github.com autorisé
✅ [PASS] Accès via proxy à api.mistral.ai autorisé
✅ [PASS] Accès via proxy à facebook.com correctement bloqué
✅ [PASS] Socket /run/docker.sock n'existe pas

🐍==== 4. Tests Spécifiques à Python ====🐍

✅ [PASS] Python 3 est disponible
✅ [PASS] pip est disponible
✅ [PASS] pip peut installer des paquets avec --user
✅ [PASS] Accès via proxy à pypi.org autorisé

⚙️==== 5. Tests de Sécurité des Processus ====⚙️

✅ [PASS] Squid tourne en tant que 'nobody' (sécurisé)
✅ [PASS] Aucune capability spéciale (sécurité maximale)

📊==== 6. Résumé des Tests ====📊

   ✅ Réussis : 14
   ❌ Échoués : 0

   🎯 Score de sécurité : 100%

   ✅ TOUS LES TESTS ONT RÉUSSI !
   Le conteneur est sécurisé et prêt pour Mistral Vibe CLI.
```

---

## 🔄 **Mise à jour**

### Mettre à jour l'image

```bash
# Tirer la dernière version de Alpine
podman pull alpine:3.20

# Reconstruire l'image sans cache
podman build --no-cache -t ia-dev-container-mistral-vibe .
```

### Mettre à jour Mistral Vibe CLI

```bash
# Dans le conteneur
pip install --user --upgrade mistral-vibe
```

---

## 💡 **Bonnes Pratiques**

1. **Ne stockez pas de secrets dans le conteneur**
   - Utilisez les variables d'environnement montées depuis l'hôte
   - Ou un gestionnaire de secrets externe

2. **Mettez à jour régulièrement**
   - L'image de base (Alpine 3.20)
   - Les paquets Python (`pip install --user --upgrade`)

3. **Ne désactivez pas le proxy**
   - Le proxy est essentiel pour la sécurité
   - Si vous avez besoin d'accéder à une nouvelle URL, ajoutez-la à `allowed-urls.txt`

4. **Utilisez des volumes pour la persistance**
   - `mistral-vibe-local` : Pour les paquets Python (`~/.local`)
   - `mistral-vibe-cache` : Pour le cache pip (`~/.cache`)
   - `workspace` : Pour votre code source

---

## ❓ **FAQ**

### **Pourquoi Podman et pas Docker ?**
Podman est **rootless par défaut**, plus sécurisé, et ne nécessite pas de daemon. Il est aussi compatible avec Docker (mêmes images, mêmes commandes).

### **Pourquoi un proxy Squid ?**
Squid permet de **filtrer les URLs** au niveau applicatif, ce qui est plus fiable que les restrictions réseau seules. Il empêche l'exfiltration de données vers des serveurs non autorisés.

### **Puis-je utiliser Docker quand même ?**
Oui, mais vous devrez ajouter manuellement :
```bash
--userns=keep-id \
--security-opt=no-new-privileges \
```

### **Comment ajouter une nouvelle URL autorisée ?**
1. Éditez `config/allowed-urls.txt`
2. Ajoutez votre domaine (un par ligne)
3. Reconstruisez l'image : `podman build -t ia-dev-container-mistral-vibe .`
4. Redémarrez le conteneur

### **Le conteneur ne démarre pas, que faire ?**
1. Vérifiez les logs :
   ```bash
   podman logs mistral-vibe-dev
   ```
2. Essayez de lancer en mode interactif :
   ```bash
   podman run --rm -it ia-dev-container-mistral-vibe bash
   ```
3. Vérifiez que Podman est bien installé :
   ```bash
   podman --version
   ```

### **Comment tester le proxy manuellement ?**
```bash
# Dans le conteneur
curl -x http://localhost:3128 https://github.com  # Doit fonctionner
curl -x http://localhost:3128 https://google.com   # Doit échouer
```

---

## 📧 **Support**

Si vous rencontrez des problèmes, vérifiez :
1. Les logs du proxy : `tail -f /var/log/squid/access.log`
2. Les tests de sécurité : `/security-tests.sh`
3. La configuration réseau : `/setup-proxy.sh`

---

## 📜 **Licence**

MIT - Libre d'utiliser, modifier et distribuer.
