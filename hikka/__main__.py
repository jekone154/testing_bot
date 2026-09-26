"""Entry point. Checks for user and starts main script"""

# ©️ Dan Gazizullin, 2021-2023
# This file is a part of Hikka Userbot
# 🌐 https://github.com/hikariatama/Hikka
# You can redistribute it and/or modify it under the terms of the GNU AGPLv3
# 🔑 https://www.gnu.org/licenses/agpl-3.0.html

import getpass
import os
import subprocess
import sys

from ._internal import restart

if (
    getpass.getuser() == "root"
    and "--root" not in " ".join(sys.argv)
    and all(trigger not in os.environ for trigger in {"DOCKER", "GOORM"})
):
    print("🚫" * 15)
    print("You attempted to run Hikka on behalf of root user")
    print("Please, create a new user and restart script")
    print("If this action was intentional, pass --root argument instead")
    print("🚫" * 15)
    print()
    print("Type force_insecure to ignore this warning")
    if input("> ").lower() != "force_insecure":
        sys.exit(1)


def _is_termux() -> bool:
    return "com.termux" in os.environ.get("PREFIX", "")


def deps():
    requirements_path = "requirements.txt"

    if _is_termux():
        # Upstream psutil refuses to build via pip on Android ("platform
        # android is not supported" -- a hard check in its own setup.py,
        # not a missing-compiler issue). On Termux it must come from
        # `pkg install python-psutil` instead, so strip it here before
        # calling pip -- otherwise this self-heal step fails on every
        # single startup where pip decides psutil needs (re)installing.
        try:
            import psutil  # noqa: F401
        except ImportError:
            print(
                "🚫 psutil is missing and cannot be installed via pip on "
                "Termux/Android.\nRun this first, then restart Hikka:\n"
                "    pkg install -y python-psutil"
            )
            sys.exit(1)

        with open("requirements.txt", encoding="utf-8") as f:
            lines = [
                line
                for line in f.readlines()
                if not line.strip().lower().startswith("psutil")
            ]

        requirements_path = "requirements.termux.txt"
        with open(requirements_path, "w", encoding="utf-8") as f:
            f.writelines(lines)

    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--upgrade",
            "-q",
            "--disable-pip-version-check",
            "--no-warn-script-location",
            "-r",
            requirements_path,
        ],
        check=True,
    )


if sys.version_info < (3, 10, 0):
    print("🚫 Error: you must use at least Python version 3.10.0")
elif __package__ != "hikka":  # In case they did python __main__.py
    print("🚫 Error: you cannot run this as a script; you must execute as a package")
else:
    try:
        import hikkatl
    except Exception:
        pass
    else:
        try:
            import hikkatl  # noqa: F811

            if tuple(map(int, hikkatl.__version__.split("."))) < (2, 0, 4):
                raise ImportError

            import hikkapyro

            if tuple(map(int, hikkapyro.__version__.split("."))) < (2, 0, 103):
                raise ImportError
        except ImportError:
            print("🔄 Installing dependencies...")
            deps()
            restart()

    try:
        from . import log

        log.init()

        from . import main
    except ImportError as e:
        print(f"{str(e)}\n🔄 Attempting dependencies installation... Just wait ⏱")
        deps()
        restart()

    if "HIKKA_DO_NOT_RESTART" in os.environ:
        del os.environ["HIKKA_DO_NOT_RESTART"]

    main.hikka.main()  # Execute main function
