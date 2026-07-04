#!/usr/bin/env python3
# Moteur d'orchestration générique du sandbox à deux conteneurs (gateway +
# workspace), partagé par tous les clients (mistral-vibe, copilot, et tout
# futur client). Invoqué par clients/*/scripts/run.sh (bash, mince) après
# qu'il a sourcé lib.sh (données propres au client) : run.sh passe ces
# données en arguments CLI explicites (voir parse_own_args() ci-dessous),
# jamais en variable globale/d'environnement implicite.
#
# Usage (identique pour tous les clients, via run.sh) :
#   run.sh up                     construit les images, crée le réseau, lance le gateway
#   run.sh shell [-- CMD...]      lance (ou réutilise) le gateway puis un workspace interactif
#   run.sh test                   lance le workspace et exécute security-tests.sh
#   run.sh down [--purge-network] arrête les conteneurs (et supprime le réseau)
#   run.sh secrets                affiche le statut des secrets attendus (voir lib.sh: SECRETS)
#   run.sh doctor                 diagnostic plateforme hôte / réseau / projet détecté
#
# Variables d'environnement (réglages utilisateur documentés, lus
# directement ici — pas des données lib.sh, donc pas de raison de les faire
# traverser la frontière CLI) :
#   GATEWAY_HARDENED=1     active la Phase 2 (nftables + abandon de privilèges)
#   GATEWAY_ADDR_MODE=static  utilise l'IP fixe du gateway au lieu de la résolution DNS
#   IA_PROJECT_NAME         force le nom utilisé pour scoper les ressources Podman
#   IA_SELF_MOUNT_RW=1      désactive l'auto-protection en lecture seule de
#                           ia-dev-containers/ dans /workspace (voir README,
#                           section Architecture)

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

WORKSPACE_SECURITY_ARGS = [
    "--userns=keep-id",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--security-opt=label=disable",
    "--read-only",
    "--tmpfs=/tmp",
    "--tmpfs=/run",
]


def sanitize_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.\-]", "-", value).lower()


def _volume_suffix(target_path: str) -> str:
    base = Path(target_path).name
    if base.startswith("."):
        base = base[1:]
    return base


@dataclasses.dataclass
class Config:
    client_name: str
    client_root: Path
    repo_root: Path
    project_root: Path
    pkg_volume_target: str
    devcontainer_display_name: str
    devcontainer_settings_json: str
    pkg_install_hint: str
    extensions: list[str]
    extra_volumes: list[str]
    secrets: list[str]  # chaque entrée : "nom-du-secret:VARIABLE_ENV"

    def __post_init__(self) -> None:
        env_project_name = os.environ.get("IA_PROJECT_NAME")
        base = env_project_name if env_project_name else self.project_root.name
        self.project_name = sanitize_name(base)

        self.gateway_hardened = os.environ.get("GATEWAY_HARDENED", "0") == "1"
        self.gateway_addr_mode = os.environ.get("GATEWAY_ADDR_MODE", "dns")

        self.gateway_base_image = "ia-dev-containers-gateway-base:latest"
        self.workspace_base_image = "ia-dev-containers-workspace-base:latest"
        self.gateway_image = f"ia-dev-containers-gateway-{self.client_name}-{self.project_name}:latest"
        self.workspace_image = f"ia-dev-containers-workspace-{self.client_name}-{self.project_name}:latest"
        self.network_name = f"ia-gw-internal-{self.client_name}-{self.project_name}"
        self.gateway_container = f"{self.client_name}-{self.project_name}-gateway"
        self.workspace_container = f"{self.client_name}-{self.project_name}-workspace"
        self.cache_volume = f"{self.client_name}-cache-{self.project_name}"
        self.pkg_volume = f"{self.client_name}-{_volume_suffix(self.pkg_volume_target)}-{self.project_name}"


# --- Auto-protection de ia-dev-containers/ contre l'écriture depuis le workspace ---
def self_protect_relpath(config: Config) -> str:
    if os.environ.get("IA_SELF_MOUNT_RW", "0") == "1":
        return ""
    if config.repo_root == config.project_root:
        return ""
    try:
        rel = config.repo_root.relative_to(config.project_root)
    except ValueError:
        return ""
    return str(rel)


def self_protect_status(config: Config) -> str:
    if os.environ.get("IA_SELF_MOUNT_RW", "0") == "1":
        return "désactivée (IA_SELF_MOUNT_RW=1)"
    if self_protect_relpath(config):
        return "active (lecture seule sur ia-dev-containers/)"
    return "non applicable (relocalisé hors du projet, ou dogfooding)"


@dataclasses.dataclass(frozen=True)
class Mount:
    source: str  # chemin hôte (bind) ou nom de volume podman (volume)
    target: str
    type: str  # "bind" | "volume" — ignoré par le rendu CLI, utilisé par le rendu JSON
    readonly: bool = False


# Jeu de mounts partagé par les deux chemins de lancement (CLI : start_workspace()
# ; VS Code : devcontainer_mounts_json()) — une seule énumération, deux rendus
# fins ci-dessous. N'inclut PAS le bind-mount principal (project_root ->
# /workspace) : chaque rendu le traite à part (workspaceMount dédié côté JSON,
# argument -v séparé côté CLI), comme le fait déjà devcontainer.json aujourd'hui.
def mounts(config: Config) -> list[Mount]:
    result: list[Mount] = []
    rel = self_protect_relpath(config)
    if rel:
        result.append(Mount(str(config.repo_root), f"/workspace/{rel}", "bind", readonly=True))
    result.append(Mount(config.pkg_volume, config.pkg_volume_target, "volume"))
    for target in config.extra_volumes:
        name = f"{config.client_name}-{_volume_suffix(target)}-{config.project_name}"
        result.append(Mount(name, target, "volume"))
    result.append(Mount(config.cache_volume, "/home/devuser/.cache", "volume"))
    return result


def _mount_cli_args(mount: Mount) -> list[str]:
    spec = f"{mount.source}:{mount.target}"
    if mount.readonly:
        spec += ":ro"
    return ["-v", spec]


def proxy_url(config: Config, gateway_ip: str | None) -> str:
    if config.gateway_addr_mode == "static":
        return f"http://{gateway_ip}:3128"
    return "http://gateway:3128"


# --- Allocation de subnet par (projet, client) ---
# squid.conf (workspace_net) et gateway.nft acceptent tout 10.89.0.0/16 :
# chaque réseau --internal reçoit un /24 déterministe dans cette plage
# (dérivé du chemin absolu du projet), avec repli séquentiel en cas de
# collision. zlib.crc32 (stdlib) plutôt que `cksum` (pas de compatibilité à
# préserver avec l'ancien algorithme : rien ne compare cette valeur à une
# référence externe, seul le réseau réellement créé fait foi — voir
# ensure_network_and_ip(), qui relit le subnet réel via `podman network
# inspect` si le réseau existe déjà).
def _subnet_offset_seed(config: Config) -> int:
    data = f"{config.project_root}:{config.client_name}".encode()
    return zlib.crc32(data)


def _podman_network_exists(name: str) -> bool:
    return subprocess.run(
        ["podman", "network", "exists", name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def _podman_network_subnet(name: str) -> str:
    result = subprocess.run(
        ["podman", "network", "inspect", name, "--format", "{{(index .Subnets 0).Subnet}}"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def ensure_network_and_ip(config: Config) -> tuple[str, str]:
    if _podman_network_exists(config.network_name):
        subnet = _podman_network_subnet(config.network_name)
    else:
        offset = (_subnet_offset_seed(config) % 240) + 10
        print(f"🔧 Création du réseau interne {config.network_name} (--internal)...")
        subnet = ""
        created = False
        last_err = ""
        for _ in range(20):
            subnet = f"10.89.{offset}.0/24"
            result = subprocess.run(
                ["podman", "network", "create", "--internal", "--subnet", subnet, config.network_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
            if result.returncode == 0:
                created = True
                break
            last_err = result.stderr.strip()
            offset += 1
            if offset > 249:
                offset = 10
        if not created:
            # N'importe quelle erreur (pas seulement une collision de subnet)
            # fait échouer chaque essai de la boucle : sur Windows/podman
            # machine avec le bug nftables #25201 par exemple, TOUTES les
            # tentatives échoueraient pour la même raison. Afficher la
            # dernière erreur réelle plutôt qu'un message générique.
            print(f"❌ Impossible de créer {config.network_name} après 20 essais de subnet.", file=sys.stderr)
            print(f"   Dernière erreur podman : {last_err}", file=sys.stderr)
            print("   Si l'erreur mentionne nftables sur Windows (podman machine), voir docs/windows.md.", file=sys.stderr)
            sys.exit(1)
    gateway_ip = ".".join(subnet.split(".")[:3]) + ".2"
    return subnet, gateway_ip


# --- Rendu JSON (devcontainer.json) ---
# Le squelette est du JSONC (commentaires `//` inclus) : on reste en
# templating par substitution de jetons (pas de dict -> json.dump(), qui
# perdrait les commentaires), mais chaque valeur insérée passe par
# json.dumps(value)[1:-1] (échappement JSON correct d'un fragment de
# chaîne — corrige un vrai bug de l'ancien échappeur `sed`, qui ne gère pas
# un guillemet double littéral dans un chemin de projet).
def _json_fragment(value: str) -> str:
    return json.dumps(value)[1:-1]


# Jointure d'un bloc JSON multi-lignes, seule logique vraiment partagée entre
# les trois rendus ci-dessous : la variation entre eux n'est pas un « style »
# mais un fait structurel — le bloc est-il suivi d'autre contenu dans le même
# tableau JSON ? WORKSPACE_SECURITY_ARGS l'est toujours (runArgs continue avec
# --network=...), mounts/extensions ne le sont jamais (rien d'autre dans leur
# tableau). Ne fait QUE la jointure/les virgules — l'échappement par champ
# reste à la charge de chaque appelant (_json_fragment), pas de ce helper.
def _json_array_block(lines: list[str], *, trailing_comma_on_last: bool) -> str:
    if not lines:
        return ""
    if trailing_comma_on_last:
        return "\n".join(f"{line}," for line in lines)
    return ",\n".join(lines)


def workspace_security_args_json() -> str:
    lines = [f'    "{_json_fragment(arg)}"' for arg in WORKSPACE_SECURITY_ARGS]
    return _json_array_block(lines, trailing_comma_on_last=True)


def _mount_json_content(mount: Mount) -> str:
    content = f"source={_json_fragment(mount.source)},target={_json_fragment(mount.target)},type={mount.type}"
    if mount.readonly:
        content += ",readonly"
    return content


def devcontainer_mounts_json(config: Config) -> str:
    lines = [f'    "{_mount_json_content(m)}"' for m in mounts(config)]
    return _json_array_block(lines, trailing_comma_on_last=False)


def devcontainer_extensions_json(config: Config) -> str:
    lines = [f'        "{_json_fragment(ext)}"' for ext in config.extensions]
    return _json_array_block(lines, trailing_comma_on_last=False)


def render_devcontainer(config: Config, gateway_ip: str | None) -> None:
    template_path = config.repo_root / "scripts" / "devcontainer-skeleton.json.template"
    out_path = config.client_root / ".devcontainer" / "devcontainer.json"
    if not template_path.is_file():
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)

    template = template_path.read_text(encoding="utf-8")
    replacements = {
        "__NETWORK_NAME__": _json_fragment(config.network_name),
        "__PROJECT_ROOT__": _json_fragment(str(config.project_root)),
        "__ALL_MOUNTS__": devcontainer_mounts_json(config),
        "__WORKSPACE_SECURITY_ARGS__": workspace_security_args_json(),
        "__PROXY_URL__": _json_fragment(proxy_url(config, gateway_ip)),
        "__CLIENT_NAME__": _json_fragment(config.client_name),
        "__DEVCONTAINER_DISPLAY_NAME__": _json_fragment(config.devcontainer_display_name),
        "__PKG_INSTALL_HINT__": _json_fragment(config.pkg_install_hint),
        "__DEVCONTAINER_EXTENSIONS__": devcontainer_extensions_json(config),
        # Fragment JSON brut fourni tel quel par lib.sh (déjà syntaxiquement
        # valide, virgule finale incluse) : insertion verbatim, pas
        # d'échappement JSON (qui casserait les guillemets/deux-points).
        "__DEVCONTAINER_SETTINGS__": config.devcontainer_settings_json,
    }
    for token, value in replacements.items():
        template = template.replace(token, value)
    out_path.write_text(template, encoding="utf-8")


# --- Podman : préflight, images, gateway, workspace, secrets ---

def preflight_platform_check() -> None:
    system = platform.system()
    if system == "Linux":
        return
    if system not in ("Darwin", "Windows"):
        print(f"⚠️  Plateforme hôte non reconnue ({system}) — poursuite sans vérification podman machine.", file=sys.stderr)
        return

    result = subprocess.run(["podman", "machine", "list", "-q"], capture_output=True, text=True)
    machine_names = result.stdout.strip()
    if not machine_names:
        print(
            "❌ Aucune VM \"podman machine\" détectée sur cette plateforme (macOS/Windows).\n"
            "   Podman a besoin d'une machine virtuelle Linux pour fonctionner ici. Lancez :\n"
            "     podman machine init\n"
            "     podman machine start\n"
            "   puis relancez cette commande. Voir docs/macos.md ou docs/windows.md.",
            file=sys.stderr,
        )
        sys.exit(1)

    result = subprocess.run(["podman", "machine", "list", "--format", "json"], capture_output=True, text=True)
    machine_json = result.stdout.strip()
    if machine_json:
        try:
            machines = json.loads(machine_json)
            running = any(m.get("Running") for m in machines)
        except (json.JSONDecodeError, TypeError, AttributeError):
            running = bool(re.search(r'"Running"\s*:\s*true', machine_json))
        if not running:
            print("⚠️  Aucune VM podman machine ne semble démarrée. Si la suite échoue :", file=sys.stderr)
            print("     podman machine start", file=sys.stderr)


def need_podman() -> None:
    if shutil.which("podman") is None:
        print("❌ podman n'est pas installé", file=sys.stderr)
        sys.exit(1)
    preflight_platform_check()


def build_images(config: Config) -> None:
    print("🔧 Construction des images...")
    subprocess.run(["podman", "build", "-t", config.gateway_base_image, str(config.repo_root / "gateway-base")], check=True)
    subprocess.run(["podman", "build", "-t", config.workspace_base_image, str(config.repo_root / "workspace-base")], check=True)
    subprocess.run(["podman", "build", "-t", config.gateway_image, str(config.client_root / "gateway")], check=True)
    # Contexte = racine du dépôt (pas client_root) pour que le Dockerfile
    # puisse COPY scripts/security-tests.sh, partagé entre clients.
    subprocess.run(
        [
            "podman", "build", "-t", config.workspace_image,
            "-f", str(config.client_root / "workspace" / "Dockerfile"),
            str(config.repo_root),
        ],
        check=True,
    )


def gateway_running(config: Config) -> bool:
    exists = subprocess.run(
        ["podman", "container", "exists", config.gateway_container],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not exists:
        return False
    result = subprocess.run(
        ["podman", "inspect", "-f", "{{.State.Running}}", config.gateway_container],
        capture_output=True, text=True,
    )
    return result.stdout.strip() == "true"


def start_gateway(config: Config, gateway_ip: str) -> None:
    if gateway_running(config):
        result = subprocess.run(
            ["podman", "inspect", "-f", "{{.HostConfig.CapAdd}}", config.gateway_container],
            capture_output=True, text=True,
        )
        running_mode = "durci" if "NET_ADMIN" in result.stdout else "simple"
        print(f"ℹ️  Gateway déjà démarré (mode {running_mode}).")
        return

    subprocess.run(["podman", "rm", "-f", config.gateway_container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    cap_args = ["--cap-drop=ALL"]
    user_args: list[str] = []
    if config.gateway_hardened:
        cap_args += ["--cap-add=NET_ADMIN", "--cap-add=NET_RAW", "--cap-add=SETUID", "--cap-add=SETGID"]
        print("🚀 Démarrage du gateway (Phase 2 : nftables + abandon de privilèges)...")
    else:
        user_args += ["--user", "65534:65534"]
        print("🚀 Démarrage du gateway (Phase 1 : non-root direct, sans nftables)...")

    subprocess.run(
        [
            "podman", "run", "-d", "--name", config.gateway_container,
            *user_args,
            *cap_args,
            "--security-opt=no-new-privileges",
            "--read-only", "--tmpfs=/tmp", "--tmpfs=/run",
            f"--network={config.network_name}:ip={gateway_ip},alias=gateway",
            "--network=podman",
            "-e", f"ENABLE_NFT={'1' if config.gateway_hardened else '0'}",
            config.gateway_image,
        ],
        stdout=subprocess.DEVNULL, check=True,
    )
    print(f"✅ Gateway démarré ({config.gateway_container})")


def _podman_secret_exists(name: str) -> bool:
    return subprocess.run(
        ["podman", "secret", "exists", name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def secret_args(config: Config) -> list[str]:
    args: list[str] = []
    for entry in config.secrets:
        secret_name, _, var_name = entry.partition(":")
        if _podman_secret_exists(secret_name):
            args += ["--secret", f"{secret_name},type=env,target={var_name}"]
    return args


def list_secrets(config: Config) -> None:
    print("Secrets attendus pour ce client :")
    env_file = config.client_root / ".env"
    env_keys: set[str] = set()
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                env_keys.add(line.split("=", 1)[0])
    for entry in config.secrets:
        secret_name, _, var_name = entry.partition(":")
        if _podman_secret_exists(secret_name):
            print(f"  {var_name} : ✅ défini (podman secret '{secret_name}')")
        elif var_name in env_keys:
            print(f"  {var_name} : ✅ défini (.env, repli — la valeur apparaît en clair dans 'podman inspect')")
        else:
            print(f"  {var_name} : ❌ absent — printf '%s' 'valeur' | podman secret create {secret_name} -")


def start_workspace(config: Config, gateway_ip: str, extra_args: list[str]) -> int:
    proxy = proxy_url(config, gateway_ip)
    env_file = config.client_root / ".env"
    env_args = ["--env-file", str(env_file)] if env_file.is_file() else []

    cli_mount_args = [arg for m in mounts(config) for arg in _mount_cli_args(m)]

    cmd = [
        "podman", "run", "--rm", "-it", "--name", config.workspace_container,
        "--user", f"{os.getuid()}:{os.getgid()}",
        *WORKSPACE_SECURITY_ARGS,
        f"--network={config.network_name}",
        "-v", f"{config.project_root}:/workspace",
        *cli_mount_args,
        "-e", f"HTTP_PROXY={proxy}", "-e", f"HTTPS_PROXY={proxy}",
        "-e", f"IA_CLIENT={config.client_name}",
        *secret_args(config),
        *env_args,
        config.workspace_image,
        *extra_args,
    ]
    return subprocess.run(cmd).returncode


def cmd_doctor(config: Config) -> None:
    print(f"Système hôte : {platform.system()} ({platform.machine()})")
    version_result = subprocess.run(
        ["podman", "version", "--format", "{{.Client.Version}}"],
        capture_output=True, text=True,
    )
    version = version_result.stdout.strip() if version_result.returncode == 0 else "inconnu"
    print(f"podman        : {version or 'inconnu'}")
    if platform.system() != "Linux":
        print("")
        print("Machines podman :")
        subprocess.run(["podman", "machine", "list"])
    print("")
    print(f"Projet détecté : {config.project_root}")
    print(f"Nom sandbox     : {config.project_name}")
    print(f"Réseau          : {config.network_name}")
    print(f"Auto-protection : {self_protect_status(config)}")
    if _podman_network_exists(config.network_name):
        print(f"  subnet (existant) : {_podman_network_subnet(config.network_name)}")
    else:
        print("  pas encore créé — sera un /24 dans 10.89.0.0/16 (choisi par 'run.sh up')")
    print("✅ Vérifications préliminaires OK.")


# --- CLI ---

def parse_own_args(argv: list[str]) -> Config:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--client-name", required=True)
    parser.add_argument("--client-root", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--pkg-volume-target", required=True)
    parser.add_argument("--devcontainer-display-name", required=True)
    parser.add_argument("--devcontainer-settings-json", default="")
    parser.add_argument("--pkg-install-hint", required=True)
    parser.add_argument("--extension", action="append", default=[], dest="extensions")
    parser.add_argument("--extra-volume", action="append", default=[], dest="extra_volumes")
    parser.add_argument("--secret", action="append", default=[], dest="secrets")
    parsed = parser.parse_args(argv)
    return Config(
        client_name=parsed.client_name,
        client_root=parsed.client_root,
        repo_root=parsed.repo_root,
        project_root=parsed.project_root,
        pkg_volume_target=parsed.pkg_volume_target,
        devcontainer_display_name=parsed.devcontainer_display_name,
        devcontainer_settings_json=parsed.devcontainer_settings_json,
        pkg_install_hint=parsed.pkg_install_hint,
        extensions=parsed.extensions,
        extra_volumes=parsed.extra_volumes,
        secrets=parsed.secrets,
    )


USAGE = "usage: run.sh {up|shell [-- CMD...]|test|down [--purge-network]|secrets|doctor}"


def main() -> int:
    argv = sys.argv[1:]
    if "--" not in argv:
        print(USAGE, file=sys.stderr)
        return 1
    boundary = argv.index("--")
    own_args, user_args = argv[:boundary], argv[boundary + 1:]

    config = parse_own_args(own_args)
    command = user_args[0] if user_args else "shell"
    rest = user_args[1:]

    if command == "up":
        need_podman()
        build_images(config)
        _subnet, gateway_ip = ensure_network_and_ip(config)
        start_gateway(config, gateway_ip)
        render_devcontainer(config, gateway_ip)
        return 0

    if command == "shell":
        need_podman()
        build_images(config)
        _subnet, gateway_ip = ensure_network_and_ip(config)
        start_gateway(config, gateway_ip)
        if rest and rest[0] == "--":
            rest = rest[1:]
        return start_workspace(config, gateway_ip, rest)

    if command == "test":
        need_podman()
        build_images(config)
        _subnet, gateway_ip = ensure_network_and_ip(config)
        start_gateway(config, gateway_ip)
        return start_workspace(config, gateway_ip, ["/security-tests.sh"])

    if command == "down":
        subprocess.run(
            ["podman", "rm", "-f", config.gateway_container, config.workspace_container],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if rest and rest[0] == "--purge-network":
            subprocess.run(
                ["podman", "network", "rm", config.network_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        print("✅ Conteneurs arrêtés.")
        return 0

    if command == "secrets":
        need_podman()
        list_secrets(config)
        return 0

    if command == "doctor":
        need_podman()
        cmd_doctor(config)
        return 0

    print(USAGE, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
