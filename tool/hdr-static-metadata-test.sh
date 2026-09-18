#!/usr/bin/env bash
# Compiles and runs the native HDR SEI checks (test/kotlin) against
# android/app/src/main/kotlin/com/dreamplayer/app/HdrStaticMetadata.kt.
# These run outside `flutter test`, so keep this in sync when the parser changes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

java_bin="${JAVA_BIN:-java}"
kotlin_version="${KOTLIN_VERSION:-2.2.20}"
cache_root="${GRADLE_CACHE:-$HOME/.gradle/caches/modules-2/files-2.1}"
out_dir="build/hdr-static-metadata-test"

if [ ! -d "$cache_root/org.jetbrains.kotlin/kotlin-compiler-embeddable/$kotlin_version" ]; then
  echo "Kotlin $kotlin_version not found in $cache_root." >&2
  echo "Run a Gradle build first, or set KOTLIN_VERSION/GRADLE_CACHE." >&2
  exit 1
fi

compiler_jars=$(find \
  "$cache_root/org.jetbrains.kotlin/kotlin-compiler-embeddable/$kotlin_version" \
  "$cache_root/org.jetbrains.kotlin/kotlin-stdlib/$kotlin_version" \
  "$cache_root/org.jetbrains.kotlin/kotlin-script-runtime/$kotlin_version" \
  "$cache_root/org.jetbrains.kotlin/kotlin-reflect" \
  "$cache_root/org.jetbrains.kotlin/kotlin-daemon-embeddable/$kotlin_version" \
  -name '*.jar' -printf '%p:' 2>/dev/null || true)
support_jars=$(find "$cache_root/org.jetbrains.kotlinx" "$cache_root/org.jetbrains/annotations" \
  -name '*.jar' -printf '%p:' 2>/dev/null || true)
stdlib_jar=$(find "$cache_root/org.jetbrains.kotlin/kotlin-stdlib/$kotlin_version" -name '*.jar' | head -1)

mkdir -p "$out_dir"
"$java_bin" -cp "$compiler_jars$support_jars" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -classpath "$stdlib_jar" -d "$out_dir" \
  android/app/src/main/kotlin/com/dreamplayer/app/HdrStaticMetadata.kt \
  test/kotlin/HdrStaticMetadataTest.kt
"$java_bin" -cp "$out_dir:$stdlib_jar" com.dreamplayer.app.HdrStaticMetadataTestKt
