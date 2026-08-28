#!/usr/bin/env python3
"""Copies the Homebrew dylibs the app links against into the bundle and
rewrites their install names, so the app runs on a machine that has never
seen Homebrew. Must run before code signing: changing a Mach-O invalidates
any signature already applied."""
import os, shutil, subprocess, sys

PREFIXES = ("/opt/homebrew", "/usr/local/opt", "/usr/local/lib")


def deps(binary):
    out = subprocess.run(["otool", "-L", binary], capture_output=True, text=True).stdout
    return [l.strip().split(" ")[0] for l in out.splitlines()[1:]
            if l.strip().startswith(PREFIXES)]


def closure(roots):
    seen, queue = set(), list(roots)
    while queue:
        for dep in deps(queue.pop()):
            if dep not in seen and os.path.exists(dep):
                seen.add(dep)
                queue.append(dep)
    return seen


def main():
    app = sys.argv[1]
    contents = os.path.join(app, "Contents")
    frameworks = os.path.join(contents, "Frameworks")
    main_exe = os.path.join(contents, "MacOS", "CADViewer")
    appex_exes = [os.path.join(contents, "PlugIns", f"{n}.appex",
                               "Contents", "MacOS", n)
                  for n in ("CADThumbnail", "CADPreview")]
    binaries = [b for b in [main_exe] + appex_exes if os.path.exists(b)]

    libs = closure(binaries)
    os.makedirs(frameworks, exist_ok=True)
    for lib in libs:
        dest = os.path.join(frameworks, os.path.basename(lib))
        if not os.path.exists(dest):
            shutil.copy2(lib, dest)
            os.chmod(dest, 0o755)

    names = {lib: "@rpath/" + os.path.basename(lib) for lib in libs}

    # Every copied dylib gets a self-referential id and rewritten dependencies.
    for lib in libs:
        dest = os.path.join(frameworks, os.path.basename(lib))
        subprocess.run(["install_name_tool", "-id", names[lib], dest],
                       capture_output=True)
        for dep in deps(dest):
            if dep in names:
                subprocess.run(["install_name_tool", "-change", dep, names[dep], dest],
                               capture_output=True)

    # Frameworks sits at Contents/Frameworks; the appex executable is four
    # levels deeper than the app executable.
    rpaths = {main_exe: "@executable_path/../Frameworks"}
    for exe in appex_exes:
        rpaths[exe] = "@executable_path/../../../../Frameworks"
    for binary in binaries:
        for dep in deps(binary):
            if dep in names:
                subprocess.run(["install_name_tool", "-change", dep, names[dep], binary],
                               capture_output=True)
        subprocess.run(["install_name_tool", "-add_rpath", rpaths[binary], binary],
                       capture_output=True)
        # Drop the build machine's library path, which would otherwise be
        # searched first and shadow the copies we just bundled.
        for stale in ("/opt/homebrew/lib", "/usr/local/lib"):
            subprocess.run(["install_name_tool", "-delete_rpath", stale, binary],
                           capture_output=True)

    size = sum(os.path.getsize(os.path.join(frameworks, f))
               for f in os.listdir(frameworks))
    print(f"bundled {len(libs)} dylibs ({size/1e6:.0f} MB) into Contents/Frameworks")


if __name__ == "__main__":
    main()
