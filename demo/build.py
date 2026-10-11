"""
Build the demo playground.
"""

import contextlib
import subprocess
import sys
import os
import glob
import shutil

build_script_mtime = os.path.getmtime(__file__)

def builder(output, inputs):
    """
    Return a decorator that:
    * Is used to wrap functions that receive no parameter and return an
      `int`, using 0 to indicate a normal exit.
    * Skips the call to the wrapped function when:
      - All files in `inputs` are older than `output` (last modified
        time is checked), or
      - This build script itself has been modified after the `output`
        was modified.
    * Prints out informational messages to stdout when the wrapped
      function is called.
    """
    def _decorator(func):
        func_name = getattr(func, "__name__", "?")
        def _print(message):
            print(f"[{func_name}] {message}")
        def _decorated():
            _print(f"{inputs} -> {output}")
            try:
                out_time = os.path.getmtime(output)
            except OSError:
                pass
            else:
                if build_script_mtime < out_time:
                    for in_file in inputs:
                        try:
                            src_time = os.path.getmtime(in_file)
                        except OSError as exc:
                            _print(f"ERROR: {in_file}: {exc}")
                            return 1
                        if src_time >= out_time:
                            break
                    else:
                        _print(f"using cache")
                        return 0
            return func()
        return _decorated
    return _decorator

def _make_static_builder(in_file: str, out_file: str | None = None):
    if out_file is None:
        out_file = in_file
    f_out = f"demo/dist/{out_file}"
    f_in = f"demo/{in_file}"
    @builder(f_out, [f_in])
    def copy_static():
        shutil.copyfile(f_in, f_out)
        return 0
    return copy_static

PGEN_SOURCE = glob.glob('src/**/*.zig', recursive=True)

@builder("demo/build/bin/pgen-bridge.wasm", ["demo/bridge.zig", "build.zig", *PGEN_SOURCE])
def build_bridge():
    cp = subprocess.run([
        'zig', 'build',
        '-Denable-demo', '-Dtarget=wasm32-freestanding',
        '--prefix', './demo/build/'
    ])
    return cp.returncode

build_play_html = _make_static_builder('play.html')
build_html = _make_static_builder('index.html')
build_js = _make_static_builder('pgen-demo.js')
build_css = _make_static_builder('play-styles.css')
copy_wasm = _make_static_builder('build/bin/pgen-bridge.wasm', 'pgen-bridge.wasm')

def main() -> int:
    with contextlib.suppress(FileExistsError):
        os.mkdir("demo/build")
    with contextlib.suppress(FileExistsError):
        os.mkdir("demo/dist")
    return (
        build_bridge()
        or copy_wasm()
        or build_play_html()
        or build_html()
        or build_js()
        or build_css()
    )

if __name__ == "__main__":
    sys.exit(main())
