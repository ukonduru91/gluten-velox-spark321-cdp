"""Assemble the final Spark 3.2.1-compatible Gluten bundle.

Takes the bundle rebuilt against Spark 3.2.1 and overlays, from the official 1.5.0 release jar,
the pieces that must stay byte-identical to the native build:
  - org/apache/arrow/**   (Gluten's patched Arrow 15.0.0-gluten Java classes; JNI peers of the .so)
  - linux/amd64/*.so      (libgluten.so, libvelox.so)
  - x86_64/*.so           (Arrow JNI libs)

usage: python assemble_jar.py <rebuilt.jar> <official.jar> <out.jar>
"""
import sys
import zipfile

OVERLAY = ("org/apache/arrow/", "linux/", "x86_64/")
DROP = ("aarch_64/",)  # stock (unpatched) ARM Arrow JNI libs from Maven; this build is x86_64 only

rebuilt, official, out = sys.argv[1:4]
with zipfile.ZipFile(rebuilt) as r, zipfile.ZipFile(official) as o:
    off_names = {n for n in o.namelist() if n.startswith(OVERLAY)}
    new_names = set(r.namelist())

    # Classes the official jar has that the rebuild lacks (outside the overlay) - informational.
    missing = sorted(n for n in set(o.namelist()) - new_names
                     if n.endswith(".class") and not n.startswith(OVERLAY))
    pkgs = sorted({"/".join(n.split("/")[:5]) for n in missing})
    print(f"official-only classes not in rebuild: {len(missing)} in packages: {pkgs[:15]}")

    written = set()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as w:
        for info in r.infolist():
            if info.filename.startswith(DROP):
                continue
            if info.filename.startswith(OVERLAY) and info.filename in off_names:
                continue  # replaced by the official copy below
            w.writestr(info, r.read(info.filename))
            written.add(info.filename)
        for name in sorted(off_names):
            if name not in written:
                w.writestr(o.getinfo(name), o.read(name))
                written.add(name)
    print(f"wrote {out}: {len(written)} entries ({len(off_names)} from official release)")
