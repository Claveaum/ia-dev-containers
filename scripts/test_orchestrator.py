#!/usr/bin/env python3
# Tests rapides, sans Podman, de scripts/orchestrator.py — remplace
# scripts/common-tests.sh (bash). Pas un remplacement de security-tests.sh
# (qui reste le seul test vérifiant les garanties réelles du sandbox), un
# complément pour vérifier vite la logique d'orchestration elle-même
# (calcul de noms de ressources, échappement JSON, mount d'auto-protection,
# rendu devcontainer.json) sans avoir à booter de conteneur.
# Usage : python3 scripts/test_orchestrator.py  (ou -m unittest depuis la racine)
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import orchestrator as orch  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def _clean_env(testcase: unittest.TestCase) -> None:
    patcher = unittest.mock.patch.dict(os.environ)
    patcher.start()
    testcase.addCleanup(patcher.stop)
    for name in ("IA_PROJECT_NAME", "IA_SELF_MOUNT_RW", "GATEWAY_ADDR_MODE", "GATEWAY_HARDENED"):
        os.environ.pop(name, None)


def _make_config(**overrides) -> orch.Config:
    defaults = dict(
        client_name="test-client",
        client_root=Path("/tmp/mon-projet/ia-dev-containers/clients/test-client"),
        repo_root=Path("/tmp/mon-projet/ia-dev-containers"),
        project_root=Path("/tmp/mon-projet"),
        pkg_volume_target="/home/devuser/.local",
        devcontainer_display_name="Test Client",
        devcontainer_settings_json="",
        pkg_install_hint="pip install --user test-client",
        extensions=[],
        extra_volumes=[],
        secrets=[],
    )
    defaults.update(overrides)
    return orch.Config(**defaults)


class NameDerivationTests(unittest.TestCase):
    def setUp(self) -> None:
        _clean_env(self)
        self.config = _make_config()

    def test_project_name(self) -> None:
        self.assertEqual(self.config.project_name, "mon-projet")

    def test_gateway_image(self) -> None:
        self.assertEqual(self.config.gateway_image, "ia-dev-containers-gateway-test-client-mon-projet:latest")

    def test_workspace_image(self) -> None:
        self.assertEqual(self.config.workspace_image, "ia-dev-containers-workspace-test-client-mon-projet:latest")

    def test_network_name(self) -> None:
        self.assertEqual(self.config.network_name, "ia-gw-internal-test-client-mon-projet")

    def test_cache_volume(self) -> None:
        # Scopé par projet (comme pkg_volume) : un CLI compromis dans un projet
        # ne doit pas pouvoir empoisonner le cache pip/npm réutilisé par un autre.
        self.assertEqual(self.config.cache_volume, "test-client-cache-mon-projet")

    def test_pkg_volume(self) -> None:
        # Vérifié équivalent aux noms historiques ("mistral-vibe-local-$PROJECT_NAME",
        # "copilot-npm-global-$PROJECT_NAME"), dérivés par _volume_suffix().
        self.assertEqual(self.config.pkg_volume, "test-client-local-mon-projet")

    def test_project_name_override_via_env(self) -> None:
        os.environ["IA_PROJECT_NAME"] = "Autre Projet"
        config = _make_config()
        self.assertEqual(config.project_name, "autre-projet")


class SanitizeNameTests(unittest.TestCase):
    def test_lowercase_and_dashes(self) -> None:
        self.assertEqual(orch.sanitize_name("AT&T Project"), "at-t-project")


class JsonFragmentTests(unittest.TestCase):
    # Remplace les cas sed_escape ampersand/pipe de l'ancienne suite bash —
    # _json_fragment() doit être un échappement JSON correct, pas juste sûr
    # pour sed. Couvre en particulier le cas que l'ancien échappeur `sed` ne
    # gérait pas du tout : un guillemet double littéral dans une valeur.
    def test_ampersand_and_pipe_pass_through_unescaped(self) -> None:
        self.assertEqual(orch._json_fragment("/chemin/AT&T"), "/chemin/AT&T")
        self.assertEqual(orch._json_fragment("a|b"), "a|b")

    def test_double_quote_is_escaped(self) -> None:
        self.assertEqual(orch._json_fragment('AT"T'), 'AT\\"T')

    def test_backslash_is_escaped(self) -> None:
        self.assertEqual(orch._json_fragment("a\\b"), "a\\\\b")


class ProxyUrlTests(unittest.TestCase):
    def setUp(self) -> None:
        _clean_env(self)

    def test_dns_mode_default(self) -> None:
        config = _make_config()
        self.assertEqual(orch.proxy_url(config, gateway_ip=None), "http://gateway:3128")

    def test_static_mode(self) -> None:
        os.environ["GATEWAY_ADDR_MODE"] = "static"
        config = _make_config()
        self.assertEqual(orch.proxy_url(config, gateway_ip="10.89.42.2"), "http://10.89.42.2:3128")


class WorkspaceSecurityArgsTests(unittest.TestCase):
    def test_seven_flags_json(self) -> None:
        expected = (
            '    "--userns=keep-id",\n'
            '    "--cap-drop=ALL",\n'
            '    "--security-opt=no-new-privileges",\n'
            '    "--security-opt=label=disable",\n'
            '    "--read-only",\n'
            '    "--tmpfs=/tmp",\n'
            '    "--tmpfs=/run",'
        )
        self.assertEqual(orch.workspace_security_args_json(), expected)


class SelfProtectionTests(unittest.TestCase):
    def setUp(self) -> None:
        _clean_env(self)

    def test_in_tree_standard(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/mon-projet/ia-dev-containers"),
            project_root=Path("/tmp/mon-projet"),
        )
        self.assertEqual(orch.self_protect_relpath(config), "ia-dev-containers")
        self.assertEqual(orch.self_protect_status(config), "active (lecture seule sur ia-dev-containers/)")

    def test_dogfooding(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/mon-projet"),
            project_root=Path("/tmp/mon-projet"),
        )
        self.assertEqual(orch.self_protect_relpath(config), "")
        self.assertEqual(
            orch.self_protect_status(config),
            "non applicable (relocalisé hors du projet, ou dogfooding)",
        )

    def test_relocated_outside_project_tree(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/ailleurs/ia-dev-containers"),
            project_root=Path("/tmp/mon-projet"),
        )
        self.assertEqual(orch.self_protect_relpath(config), "")

    def test_escape_hatch(self) -> None:
        os.environ["IA_SELF_MOUNT_RW"] = "1"
        config = _make_config(
            repo_root=Path("/tmp/mon-projet/ia-dev-containers"),
            project_root=Path("/tmp/mon-projet"),
        )
        self.assertEqual(orch.self_protect_relpath(config), "")
        self.assertEqual(orch.self_protect_status(config), "désactivée (IA_SELF_MOUNT_RW=1)")


class MountsTests(unittest.TestCase):
    # mounts(config) est la seule énumération du jeu de mounts, partagée par
    # start_workspace() (CLI) et devcontainer_mounts_json() (VS Code) — ce
    # test remplace les anciennes assertions sur self_protect_mount_args() et
    # extra_volume_mount_args() (supprimées), en vérifiant directement la
    # composition et l'ordre canonique (auto-protection, pkg, extras, cache).
    def setUp(self) -> None:
        _clean_env(self)

    def test_in_tree_without_extra_volumes(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/mon-projet/ia-dev-containers"),
            project_root=Path("/tmp/mon-projet"),
        )
        self.assertEqual(
            orch.mounts(config),
            [
                orch.Mount("/tmp/mon-projet/ia-dev-containers", "/workspace/ia-dev-containers", "bind", readonly=True),
                orch.Mount("test-client-local-mon-projet", "/home/devuser/.local", "volume"),
                orch.Mount("test-client-cache-mon-projet", "/home/devuser/.cache", "volume"),
            ],
        )

    def test_in_tree_with_extra_volumes(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/mon-projet/ia-dev-containers"),
            project_root=Path("/tmp/mon-projet"),
            extra_volumes=["/home/devuser/.copilot"],
        )
        self.assertEqual(
            orch.mounts(config),
            [
                orch.Mount("/tmp/mon-projet/ia-dev-containers", "/workspace/ia-dev-containers", "bind", readonly=True),
                orch.Mount("test-client-local-mon-projet", "/home/devuser/.local", "volume"),
                orch.Mount("test-client-copilot-mon-projet", "/home/devuser/.copilot", "volume"),
                orch.Mount("test-client-cache-mon-projet", "/home/devuser/.cache", "volume"),
            ],
        )

    def test_dogfooding_no_self_protect_entry(self) -> None:
        config = _make_config(
            repo_root=Path("/tmp/mon-projet"),
            project_root=Path("/tmp/mon-projet"),
        )
        result = orch.mounts(config)
        self.assertTrue(all(m.type != "bind" for m in result))
        self.assertEqual(len(result), 2)  # pkg + cache, pas d'auto-protection

    def test_extra_volume_basename_collision_raises(self) -> None:
        # _volume_suffix() ne garde que le basename : deux EXTRA_VOLUMES sous
        # des répertoires différents mais de même nom de fichier final
        # produiraient le même nom de volume Podman sans cette garde.
        config = _make_config(
            repo_root=Path("/tmp/mon-projet"),
            project_root=Path("/tmp/mon-projet"),
            extra_volumes=["/home/devuser/.config/state", "/home/devuser/.other/state"],
        )
        with self.assertRaises(ValueError):
            orch.mounts(config)


class CommandDispatchTests(unittest.TestCase):
    # COMMANDS est la table utilisée par main() pour l'aiguillage — ce test
    # échoue si une commande est ajoutée/retirée de USAGE sans être répercutée
    # dans COMMANDS (ou l'inverse), ce que main() ne vérifiait pas avant que
    # le dispatch ne devienne une table plutôt qu'une chaîne if/elif.
    def test_commands_table_matches_documented_usage(self) -> None:
        self.assertEqual(
            set(orch.COMMANDS),
            {"up", "shell", "test", "exec", "down", "purge", "logs", "secrets", "doctor"},
        )

    def test_unknown_command_has_no_handler(self) -> None:
        self.assertNotIn("bogus", orch.COMMANDS)


class HandleTestAggregationTests(unittest.TestCase):
    # handle_test() doit faire échouer `run.sh test` si gateway-checks.sh
    # échoue, pas seulement si security-tests.sh (via start_workspace)
    # échoue — avant ce candidat, le code de sortie de gateway-checks.sh
    # était silencieusement jeté (voir revue d'architecture, candidat A).
    def setUp(self) -> None:
        _clean_env(self)
        self.config = _make_config()

    def _run_with(self, gateway_rc: int, workspace_rc: int) -> int:
        with unittest.mock.patch.object(orch, "_bring_up_gateway", return_value="10.89.0.2"), \
             unittest.mock.patch.object(orch.subprocess, "run") as mock_run, \
             unittest.mock.patch.object(orch, "start_workspace", return_value=workspace_rc):
            mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=gateway_rc)
            return orch.handle_test(self.config, [])

    def test_gateway_failure_wins_over_workspace_success(self) -> None:
        self.assertEqual(self._run_with(gateway_rc=1, workspace_rc=0), 1)

    def test_workspace_failure_reported_when_gateway_ok(self) -> None:
        self.assertEqual(self._run_with(gateway_rc=0, workspace_rc=1), 1)

    def test_both_pass(self) -> None:
        self.assertEqual(self._run_with(gateway_rc=0, workspace_rc=0), 0)


def _client_config_from_lib_sh(lib_sh_path: Path, client_root: Path) -> orch.Config:
    # Sourcé en bash (lib.sh reste bash, y compris pour ce test — voir
    # CLAUDE.md) puis construit la même liste d'arguments CLI que run.sh,
    # transmise NUL-séparée pour rester correcte sur une valeur multi-lignes
    # (DEVCONTAINER_SETTINGS_JSON) sans jamais repasser par un échappement
    # sed/JSON maison.
    script = f'''
source "{lib_sh_path}"
args=()
args+=(--client-name "$CLIENT_NAME")
args+=(--pkg-volume-target "$PKG_VOLUME_TARGET")
args+=(--devcontainer-display-name "$DEVCONTAINER_DISPLAY_NAME")
args+=(--devcontainer-settings-json "$DEVCONTAINER_SETTINGS_JSON")
args+=(--pkg-install-hint "$PKG_INSTALL_HINT")
for ext in "${{DEVCONTAINER_EXTENSIONS[@]+"${{DEVCONTAINER_EXTENSIONS[@]}}"}}"; do
    args+=(--extension "$ext")
done
for vol in "${{EXTRA_VOLUMES[@]+"${{EXTRA_VOLUMES[@]}}"}}"; do
    args+=(--extra-volume "$vol")
done
for secret in "${{SECRETS[@]+"${{SECRETS[@]}}"}}"; do
    args+=(--secret "$secret")
done
printf '%s\\0' "${{args[@]}}"
'''
    result = subprocess.run(["bash", "-c", script], capture_output=True, check=True)
    raw_tokens = result.stdout.split(b"\0")
    if raw_tokens and raw_tokens[-1] == b"":
        raw_tokens = raw_tokens[:-1]  # artefact du séparateur final de printf, pas une valeur
    tokens = [tok.decode("utf-8") for tok in raw_tokens]
    tokens += [
        "--client-root", str(client_root),
        "--repo-root", str(REPO_ROOT),
        "--project-root", str(REPO_ROOT.parent),
    ]
    return orch.parse_own_args(tokens)


def _strip_jsonc_comments(text: str) -> str:
    # Ne retire que les lignes ENTIÈREMENT commentaires (après espaces de
    # tête) : un strip naïf de tout ce qui suit "//" corromprait la valeur
    # JSON réelle "http://gateway:3128" présente dans postStartCommand.
    return "\n".join(line for line in text.splitlines() if not re.match(r"^\s*//", line))


class RenderDevcontainerRealClientsTests(unittest.TestCase):
    # Rendu contre le VRAI squelette partagé pour chaque client réel
    # (découverte automatique, pas une liste codée en dur : un client
    # ajouté sans toucher ce fichier doit rester couvert), sous /tmp — même
    # principe que l'ancienne suite bash : un jeton __X__ oublié dans le
    # vrai template doit être détecté, une fixture synthétique ne le verrait
    # pas.
    def setUp(self) -> None:
        _clean_env(self)

    def test_all_real_clients(self) -> None:
        clients_dir = REPO_ROOT / "clients"
        client_dirs = sorted(p for p in clients_dir.iterdir() if (p / "scripts" / "lib.sh").is_file())
        self.assertTrue(client_dirs, "aucun client trouvé sous clients/")

        for client_dir in client_dirs:
            with self.subTest(client=client_dir.name):
                with tempfile.TemporaryDirectory() as tmp:
                    client_root = Path(tmp)
                    config = _client_config_from_lib_sh(client_dir / "scripts" / "lib.sh", client_root)
                    orch.render_devcontainer(config, gateway_ip=None)

                    out = client_root / ".devcontainer" / "devcontainer.json"
                    self.assertTrue(out.is_file(), f"devcontainer.json non produit pour {client_dir.name}")

                    raw = out.read_text(encoding="utf-8")
                    orphans = sorted(set(re.findall(r"__[A-Z_]+__", raw)))
                    self.assertEqual(orphans, [], f"jeton(s) orphelin(s) pour {client_dir.name} : {orphans}")

                    stripped = _strip_jsonc_comments(raw)
                    try:
                        json.loads(stripped)
                    except json.JSONDecodeError as exc:
                        self.fail(f"JSON(C) invalide pour {client_dir.name} : {exc}")


class MainHelpAndDispatchTests(unittest.TestCase):
    # Couvre la friction ergonomique corrigée : --help/-h doit être traité
    # comme une vraie commande (stdout, exit 0), pas retomber dans la même
    # branche qu'une faute de frappe ; une invocation sans commande doit
    # prévenir avant de lancer 'shell' par défaut.
    def _run_main(self, user_args: list[str], own_args: list[str] | None = None) -> tuple[int, str, str]:
        argv = ["orchestrator.py", *(own_args or []), "--", *user_args]
        with unittest.mock.patch.object(orch.sys, "argv", argv), \
             unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
             unittest.mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            code = orch.main()
        return code, out.getvalue(), err.getvalue()

    def test_help_flag_prints_to_stdout_and_exits_zero(self) -> None:
        code, out, err = self._run_main(["--help"])
        self.assertEqual(code, 0)
        self.assertIn("Commandes :", out)
        self.assertEqual(err, "")

    def test_short_help_flag_same_as_long(self) -> None:
        code, out, _ = self._run_main(["-h"])
        self.assertEqual(code, 0)
        self.assertIn("Commandes :", out)

    def test_unknown_command_names_it_and_exits_nonzero(self) -> None:
        own_args = [
            "--client-name", "test-client", "--client-root", "/tmp/c",
            "--repo-root", "/tmp/r", "--project-root", "/tmp/p",
            "--pkg-volume-target", "/home/devuser/.local",
            "--devcontainer-display-name", "Test", "--pkg-install-hint", "pip install x",
        ]
        code, out, err = self._run_main(["bogus"], own_args)
        self.assertEqual(code, 1)
        self.assertIn("'bogus'", err)
        self.assertEqual(out, "")

    def test_no_command_warns_then_dispatches_to_shell(self) -> None:
        own_args = [
            "--client-name", "test-client", "--client-root", "/tmp/c",
            "--repo-root", "/tmp/r", "--project-root", "/tmp/p",
            "--pkg-volume-target", "/home/devuser/.local",
            "--devcontainer-display-name", "Test", "--pkg-install-hint", "pip install x",
        ]
        stub = unittest.mock.MagicMock(return_value=0)
        with unittest.mock.patch.object(orch, "need_podman"), \
             unittest.mock.patch.dict(orch.COMMANDS, {"shell": stub}):
            code, out, err = self._run_main([], own_args)
        self.assertEqual(code, 0)
        self.assertTrue(stub.called, "la commande par défaut doit rester 'shell'")
        self.assertIn("shell", err)
        self.assertIn("par défaut", err)


class HandlePurgeVolumesConfirmationTests(unittest.TestCase):
    # --volumes supprime des données réelles et irréversibles (paquets
    # installés, cache, état persistant du CLI) : ce candidat ajoute une
    # confirmation avant l'appel à `podman volume rm`, absente auparavant.
    def setUp(self) -> None:
        _clean_env(self)
        self.config = _make_config()

    def _run_purge(self, rest: list[str], isatty: bool, input_reply: str | None = None):
        calls: list[list[str]] = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return subprocess.CompletedProcess(args=cmd, returncode=0)

        patches = [
            unittest.mock.patch.object(orch, "_podman_rm_f"),
            unittest.mock.patch.object(orch.subprocess, "run", side_effect=fake_run),
            unittest.mock.patch.object(orch.sys.stdin, "isatty", return_value=isatty),
        ]
        if input_reply is not None:
            patches.append(unittest.mock.patch("builtins.input", return_value=input_reply))
        with contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            code = orch.handle_purge(self.config, rest)
        volume_rm_calls = [c for c in calls if c[:3] == ["podman", "volume", "rm"]]
        return code, volume_rm_calls

    def test_no_volumes_flag_never_touches_volumes(self) -> None:
        code, volume_rm_calls = self._run_purge([], isatty=False)
        self.assertEqual(code, 0)
        self.assertEqual(volume_rm_calls, [])

    def test_volumes_non_interactive_without_yes_is_refused(self) -> None:
        code, volume_rm_calls = self._run_purge(["--volumes"], isatty=False)
        self.assertEqual(code, 0)  # le reste de purge (images/réseau) a bien lieu
        self.assertEqual(volume_rm_calls, [])

    def test_volumes_non_interactive_with_yes_proceeds(self) -> None:
        code, volume_rm_calls = self._run_purge(["--volumes", "--yes"], isatty=False)
        self.assertEqual(code, 0)
        self.assertEqual(len(volume_rm_calls), 1)

    def test_volumes_interactive_declined(self) -> None:
        code, volume_rm_calls = self._run_purge(["--volumes"], isatty=True, input_reply="n")
        self.assertEqual(code, 0)
        self.assertEqual(volume_rm_calls, [])

    def test_volumes_interactive_accepted(self) -> None:
        code, volume_rm_calls = self._run_purge(["--volumes"], isatty=True, input_reply="y")
        self.assertEqual(code, 0)
        self.assertEqual(len(volume_rm_calls), 1)


if __name__ == "__main__":
    unittest.main()
