#!/usr/bin/env bash
# Rebuild arrow-dataset 15.0.0 with Gluten's Java patch (what Gluten calls 15.0.0-gluten) and put it
# in the build's local Maven repo in place of stock arrow-dataset 15.0.0. Only the Java classes are
# rebuilt; the matching JNI .so comes from the official Gluten release jar at assembly time.
set -euo pipefail
V=15.0.0
REPO=/root/.m2/repository
A=$REPO/org/apache/arrow
W=/tmp/arrow-dataset-patch
rm -rf $W && mkdir -p $W/src $W/classes && cd $W

mvn -B -q dependency:get -Dartifact=org.apache.arrow:arrow-dataset:$V
mvn -B -q dependency:get -Dartifact=org.apache.arrow:arrow-dataset:$V:jar:sources
JAR=$A/arrow-dataset/$V/arrow-dataset-$V.jar
[ -f $JAR.stock ] || cp $JAR $JAR.stock

# Sources + Gluten's patch, restricted to main Java sources (pom/test hunks don't apply here)
(cd src && jar xf $A/arrow-dataset/$V/arrow-dataset-$V-sources.jar)
awk '/^diff --git/ { keep = index($0, "java/dataset/src/main/java/") > 0 } keep' \
    /src/ep/build-velox/src/modify_arrow_dataset_scan_option.patch > dataset.patch
command -v patch >/dev/null || (apt-get -qq update && apt-get -qq install -y patch >/dev/null)
(cd src && patch -p6 < ../dataset.patch)

# Compile against what's already in the local repo (stock Arrow 15.0.0 and its deps, pulled in by
# the Gluten build); resolving arrow-dataset's pom would also download its test-only deps.
find $REPO -name '*.jar' ! -path '*/arrow-dataset/*' ! -name '*-sources.jar' ! -name '*-tests.jar'     ! -path '*/org/apache/gluten/*' | paste -sd: > cp.txt
# io.substrait.proto (needed by the patch): use the protos Gluten itself generates
CP="$(cat cp.txt):/src/gluten-substrait/target/scala-2.12/classes"
javac -nowarn -source 8 -target 8 -cp "$CP" -d classes $(find src -name '*.java')

# Stock jar (resources, manifest) with the patched classes on top
cp $JAR.stock arrow-dataset-patched.jar
(cd classes && jar uf ../arrow-dataset-patched.jar .)
cp arrow-dataset-patched.jar $JAR
rm -f $A/arrow-dataset/$V/_remote.repositories
echo "patched arrow-dataset installed: $(unzip -l $JAR 2>/dev/null | grep -c FragmentScanOptions || jar tf $JAR | grep -c FragmentScanOptions) FragmentScanOptions entries"
