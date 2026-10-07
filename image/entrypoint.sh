#!/bin/bash
# gluten-dist: copies the Gluten jar + scripts out of the image onto the host.
set -euo pipefail
SRC=/opt/gluten
IMAGE=upendrak/gluten-velox-spark321-cdp:1.5.0-spark3.2.1

usage() {
  cat <<EOF
Gluten 1.5.0 + Velox for Spark 3.2.1 (CDP 7.1.7 SP1 / RHEL 8)
https://github.com/ukonduru91/gluten-velox-spark321-cdp

Copy everything to /opt/gluten on the edge node (works the same with podman):

  docker run --rm -v /opt/gluten:/out $IMAGE install

Then, on the edge node (not in the container):

  /opt/gluten/cluster/run-benchmark.sh hdfs:///tmp/gluten_bench          # built-in benchmark
  /opt/gluten/cluster/run-poc.sh --class com.x.Main my-job.jar [args]     # your own job

Commands:
  install [dir]   copy jar + scripts to dir (default /out, so mount a host folder there)
  verify          check the jar's sha512 checksum
  list            list the files in the image
  help            this text
EOF
}

case "${1:-help}" in
  install)
    DEST=${2:-/out}
    [ -d "$DEST" ] || { echo "No folder at $DEST. Mount one: -v /opt/gluten:$DEST"; exit 1; }
    cp -r "$SRC"/. "$DEST"/
    # Give the files to whoever owns the target folder (not root)
    chown -R "$(stat -c %u:%g "$DEST")" "$DEST" 2>/dev/null || true
    (cd "$DEST" && sha512sum -c --quiet ./*.jar.sha512) && echo "jar checksum OK"
    echo "Installed to the folder mounted at $DEST:"
    (cd "$DEST" && ls -1 ./*.jar cluster/*.sh bench/bench.py)
    echo
    echo "Next: <host folder>/cluster/run-benchmark.sh hdfs:///tmp/gluten_bench"
    ;;
  verify)  cd "$SRC" && sha512sum -c ./*.jar.sha512 ;;
  list)    cd "$SRC" && find . -type f | sort ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
