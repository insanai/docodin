"""Build hook: compile the native library before packaging the Python code.

Package metadata lives in pyproject.toml.
"""

import os
import subprocess

from setuptools import setup
from setuptools.command.build_py import build_py


class BuildWithNativeLibrary(build_py):
    """Run ``scripts/build_odin.sh`` (requires the Odin compiler)."""

    def run(self):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "build_odin.sh")
        if os.path.exists(script):
            subprocess.check_call(["bash", script])
        super().run()


setup(cmdclass={"build_py": BuildWithNativeLibrary})
