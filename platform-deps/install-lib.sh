#!/usr/bin/env bash
# Install every jar under ./lib into a local Maven repository.
#
# GAV comes from each jar's META-INF/maven/**/pom.properties; the embedded pom.xml is
# installed alongside so Maven can resolve the public dependencies (jackson, httpclient,
# commons-*, ...) from its normal remote repositories.
#
# Jars containing META-INF/maven/plugin.xml are installed with packaging=maven-plugin so
# Maven registers them as plugins instead of plain libraries.
#
# Parent POMs are chased recursively. A parent shipped as lib/<artifactId>-<version>.pom is
# installed verbatim; a parent from a private group that exists nowhere is stubbed; a parent
# from a public group is left untouched so Maven downloads the real one (stubbing those would
# strip their dependencyManagement and break ${property} resolution in the children).
#
# Usage:
#   ./install-lib.sh
#   ./install-lib.sh /path/to/maven/repo
#   ./install-lib.sh /path/to/maven/repo --force

set -uo pipefail
cd "$(dirname "$0")"

PRIVATE_GROUPS="${PRIVATE_GROUPS:-org.datayoo}"

FORCE=0
LOCAL_REPO=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    *)          LOCAL_REPO="$arg" ;;
  esac
done

if [[ ! -d lib ]]; then
  echo "[ERROR] lib directory not found: $(pwd)/lib"
  exit 1
fi

if ! command -v mvn >/dev/null 2>&1; then
  echo "[ERROR] mvn not found in PATH"
  exit 1
fi

# Pick an interpreter that actually works: some bundled pythons (notably the msys2 one on
# Windows) are on PATH but ship a broken standard library.
PY=""
for candidate in python3 python py; do
  path="$(command -v "$candidate" 2>/dev/null)" || continue
  [[ -z "$path" ]] && continue
  if "$path" -c 'import re, zipfile, xml.etree.ElementTree' >/dev/null 2>&1; then
    PY="$path"
    break
  fi
  echo "[WARN] ignoring unusable interpreter: $path"
done
if [[ -z "$PY" ]]; then
  echo "[ERROR] no working python3 found in PATH"
  exit 1
fi

if [[ -z "$LOCAL_REPO" ]]; then
  if [[ -n "${MAVEN_REPO:-}" ]]; then
    LOCAL_REPO="$MAVEN_REPO"
  else
    read -r -p "Maven local repository path: " LOCAL_REPO
  fi
fi
if [[ -z "$LOCAL_REPO" ]]; then
  echo "[ERROR] Maven local repository path is required"
  exit 1
fi

mkdir -p "$LOCAL_REPO"
LOCAL_REPO="$(cd "$LOCAL_REPO" && pwd)"

# Under Git Bash / MSYS a unix path handed to a native Windows program is not understood.
# Arguments are translated automatically, but paths written into files are not, so anything
# handed over that way has to be converted explicitly.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    echo "$1"
  fi
}

MVN_REPO="$(native_path "$LOCAL_REPO")"

echo "Local Maven repo: $LOCAL_REPO"
echo "Private groups  : $PRIVATE_GROUPS"
if [[ "$FORCE" == "1" ]]; then
  echo "Mode            : FORCE overwrite"
else
  echo "Mode            : skip if already installed"
fi
echo

HELPER="$(mktemp -t install-lib-helper.XXXXXX.py 2>/dev/null || mktemp)"
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t install-lib)"
trap 'rm -rf "$HELPER" "$WORKDIR"' EXIT

cat > "$HELPER" <<'PYHELPER'
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

# On Windows python defaults to \r\n, which would end up inside the values the shell reads
# back and silently corrupt every path built from them.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(newline='\n')


def local(tag):
    return tag.rsplit('}', 1)[-1]


def child(node, name):
    for c in node:
        if local(c.tag) == name:
            return c
    return None


def dig(node, path):
    cur = node
    for part in path.split('/'):
        cur = child(cur, part)
        if cur is None:
            return None
    return cur


def text(node, path):
    n = dig(node, path)
    return n.text.strip() if n is not None and n.text else None


def root_of(pom):
    try:
        return ET.parse(pom).getroot()
    except Exception:
        return None


def cmd_jarmeta(jar, outdir):
    with zipfile.ZipFile(jar) as z:
        names = z.namelist()
        props = [n for n in names
                 if n.startswith('META-INF/maven/') and n.endswith('pom.properties')]
        if not props:
            return 2
        prop_text = z.read(props[0]).decode('utf-8', 'replace')

        pom_text = None
        poms = [n for n in names
                if n.startswith('META-INF/maven/') and n.endswith('pom.xml')]
        if poms:
            pom_text = z.read(poms[0]).decode('utf-8', 'replace')

        # A Maven plugin is identified by its generated descriptor, not by packaging alone.
        is_plugin = 'META-INF/maven/plugin.xml' in names
        goal_prefix = ''
        plugin_name = ''
        if is_plugin:
            desc = z.read('META-INF/maven/plugin.xml').decode('utf-8', 'replace')
            m = re.search(r'<goalPrefix>\s*([^<]+?)\s*</goalPrefix>', desc)
            if m:
                goal_prefix = m.group(1)
            m = re.search(r'<name>\s*([^<]+?)\s*</name>', desc)
            if m:
                plugin_name = m.group(1)

    gav = {}
    for line in prop_text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, v = line.split('=', 1)
        k = k.strip()
        if k in ('groupId', 'artifactId', 'version'):
            gav[k] = v.strip()
    if not all(k in gav for k in ('groupId', 'artifactId', 'version')):
        return 2

    packaging = 'jar'
    if pom_text:
        m = re.search(r'<packaging>\s*([^<]+?)\s*</packaging>', pom_text)
        if m:
            packaging = m.group(1)
    if is_plugin:
        packaging = 'maven-plugin'

    pom_path = ''
    if pom_text:
        # install-file trusts the POM over -Dpackaging, so a plugin whose POM forgot the
        # packaging would land as a plain jar and never resolve by prefix.
        if is_plugin and not re.search(r'<packaging>\s*maven-plugin\s*</packaging>', pom_text):
            if re.search(r'<packaging>\s*[^<]+?\s*</packaging>', pom_text):
                pom_text = re.sub(r'<packaging>\s*[^<]+?\s*</packaging>',
                                  '<packaging>maven-plugin</packaging>', pom_text, count=1)
            else:
                pom_text = pom_text.replace('</version>',
                                            '</version>\n  <packaging>maven-plugin</packaging>', 1)
        pom_path = os.path.join(outdir, '%s-%s.pom' % (gav['artifactId'], gav['version']))
        with open(pom_path, 'w', encoding='utf-8') as f:
            f.write(pom_text)

    print('\t'.join([gav['groupId'], gav['artifactId'], gav['version'],
                     packaging, '1' if is_plugin else '0', pom_path,
                     goal_prefix, plugin_name or gav['artifactId']]))
    return 0


def cmd_pluginmeta(meta_path, entries_file):
    """install-file never writes the group level maven-metadata-local.xml, so a plugin
    installed this way cannot be invoked by its short prefix. Merge the entries ourselves,
    keeping whatever the repository already lists."""
    entries = []
    seen = set()

    def add(aid, prefix, name):
        if aid in seen:
            for e in entries:
                if e[0] == aid:
                    e[1], e[2] = prefix, name
            return
        seen.add(aid)
        entries.append([aid, prefix, name])

    if os.path.exists(meta_path):
        r = root_of(meta_path)
        if r is not None:
            plugins = child(r, 'plugins')
            if plugins is not None:
                for p in plugins:
                    if local(p.tag) != 'plugin':
                        continue
                    aid = text(p, 'artifactId')
                    prefix = text(p, 'prefix')
                    if aid and prefix:
                        add(aid, prefix, text(p, 'name') or aid)

    with open(entries_file, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            aid, prefix, name = (line.split('\t') + ['', ''])[:3]
            add(aid, prefix, name or aid)

    os.makedirs(os.path.dirname(meta_path), exist_ok=True)
    with open(meta_path, 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<metadata>\n  <plugins>\n')
        for aid, prefix, name in entries:
            f.write('    <plugin>\n')
            f.write('      <name>%s</name>\n' % name)
            f.write('      <prefix>%s</prefix>\n' % prefix)
            f.write('      <artifactId>%s</artifactId>\n' % aid)
            f.write('    </plugin>\n')
        f.write('  </plugins>\n</metadata>\n')
    return 0


def cmd_parent(pom):
    r = root_of(pom)
    if r is None:
        return 1
    p = child(r, 'parent')
    if p is None:
        return 1
    g, a, v = text(p, 'groupId'), text(p, 'artifactId'), text(p, 'version')
    if not (g and a and v):
        return 1
    print('\t'.join([g, a, v]))
    return 0


def cmd_gav(pom):
    r = root_of(pom)
    if r is None:
        return 1
    g = text(r, 'groupId') or text(r, 'parent/groupId')
    a = text(r, 'artifactId')
    v = text(r, 'version') or text(r, 'parent/version')
    if not (g and a and v):
        return 1
    print('\t'.join([g, a, v, text(r, 'packaging') or 'jar']))
    return 0


def pom_properties(r):
    props = {}
    version = text(r, 'version') or text(r, 'parent/version')
    group = text(r, 'groupId') or text(r, 'parent/groupId')
    if version:
        props['project.version'] = version
        props['version'] = version
    if group:
        props['project.groupId'] = group
    parent_version = text(r, 'parent/version')
    if parent_version:
        props['project.parent.version'] = parent_version
        props['parent.version'] = parent_version
    declared = child(r, 'properties')
    if declared is not None:
        for p in declared:
            props[local(p.tag)] = (p.text or '').strip()
    return props


def resolve(value, props):
    for _ in range(5):
        if '${' not in value:
            return value
        value = re.sub(r'\$\{([^}]+)\}',
                       lambda m: props.get(m.group(1), m.group(0)), value)
    return None if '${' in value else value


def private_deps(pom, groups):
    r = root_of(pom)
    if r is None:
        return []
    props = pom_properties(r)
    deps = child(r, 'dependencies')
    if deps is None:
        return []
    out = []
    for d in deps:
        if local(d.tag) != 'dependency':
            continue
        g, a, v = text(d, 'groupId'), text(d, 'artifactId'), text(d, 'version')
        if not (g and a and v):
            continue
        # test/provided/optional dependencies never have to resolve for a normal build.
        if (text(d, 'scope') or '') in ('test', 'provided', 'system'):
            continue
        if (text(d, 'optional') or '') == 'true':
            continue
        g, a, v = resolve(g, props), resolve(a, props), resolve(v, props)
        if not (g and a and v):
            continue
        if not any(g == p or g.startswith(p + '.') for p in groups):
            continue
        if v in ('RELEASE', 'LATEST'):
            continue
        out.append((g, a, v))
    return out


def cmd_missing(repo, prefixes, seed_file):
    """Walk the transitive closure of private dependencies and report the ones nothing
    provides. Reporting only the first level would make the user re-run once per level."""
    groups = [p for p in prefixes.split(',') if p]
    with open(seed_file, encoding='utf-8') as f:
        queue = [line.strip() for line in f if line.strip()]

    visited = set()
    missing = []
    while queue:
        pom = queue.pop(0)
        key = os.path.normcase(os.path.abspath(pom))
        if key in visited:
            continue
        visited.add(key)

        for g, a, v in private_deps(pom, groups):
            dep_dir = os.path.join(repo, g.replace('.', os.sep), a, v)
            if not os.path.exists(os.path.join(dep_dir, '%s-%s.jar' % (a, v))):
                coord = '%s:%s:%s' % (g, a, v)
                if coord not in missing:
                    missing.append(coord)
                continue
            dep_pom = os.path.join(dep_dir, '%s-%s.pom' % (a, v))
            if os.path.exists(dep_pom):
                queue.append(dep_pom)

    for coord in sorted(missing):
        print(coord)
    return 0


if __name__ == '__main__':
    action = sys.argv[1]
    if action == 'jarmeta':
        sys.exit(cmd_jarmeta(sys.argv[2], sys.argv[3]))
    if action == 'parent':
        sys.exit(cmd_parent(sys.argv[2]))
    if action == 'gav':
        sys.exit(cmd_gav(sys.argv[2]))
    if action == 'missing':
        sys.exit(cmd_missing(sys.argv[2], sys.argv[3], sys.argv[4]))
    if action == 'pluginmeta':
        sys.exit(cmd_pluginmeta(sys.argv[2], sys.argv[3]))
    sys.exit(64)
PYHELPER

artifact_dir() {
  local gid="$1" aid="$2" ver="$3"
  echo "$LOCAL_REPO/${gid//.//}/$aid/$ver"
}

# A cached copy is only usable if Maven considers it locally installed. Artifacts downloaded
# earlier from an internal Nexus are recorded in _remote.repositories as "<file>><repoId>=",
# and once that repository is no longer configured (this project ships without one) Maven
# rejects the cached file with "Could not find artifact" even though it sits right there.
# A local install is recorded with an empty repository id instead.
is_locally_installed() {
  local directory="$1" file_name="$2"
  local marker="$directory/_remote.repositories"
  [[ -f "$marker" ]] || return 0
  grep -qE "^[[:space:]]*$(sed 's/[.[\*^$/]/\\&/g' <<< "$file_name")>[[:space:]]*=[[:space:]]*$" "$marker"
}

is_private_group() {
  local gid="$1" prefix
  local IFS=','
  for prefix in $PRIVATE_GROUPS; do
    [[ -z "$prefix" ]] && continue
    if [[ "$gid" == "$prefix" || "$gid" == "$prefix."* ]]; then
      return 0
    fi
  done
  return 1
}

write_stub_pom() {
  local gid="$1" aid="$2" ver="$3" dest="$4"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$gid</groupId>
  <artifactId>$aid</artifactId>
  <version>$ver</version>
  <packaging>pom</packaging>
</project>
EOF
}

# Walk the parent chain of an installed POM, making sure every private ancestor resolves.
install_parent_chain() {
  local current="$1"
  local seen="" line gid aid ver key dest_dir dest shipped

  while [[ -n "$current" && -f "$current" ]]; do
    line="$("$PY" "$HELPER" parent "$current" 2>/dev/null | tr -d '\r')" || break
    [[ -z "$line" ]] && break
    IFS=$'\t' read -r gid aid ver <<< "$line"
    [[ -z "$gid" || -z "$aid" || -z "$ver" ]] && break

    key="$gid:$aid:$ver"
    case "$seen" in *"|$key|"*) break ;; esac
    seen="$seen|$key|"

    dest_dir="$(artifact_dir "$gid" "$aid" "$ver")"
    dest="$dest_dir/$aid-$ver.pom"

    if [[ -f "$dest" ]]; then
      current="$dest"
      continue
    fi

    shipped="lib/$aid-$ver.pom"
    if [[ -f "$shipped" ]]; then
      mkdir -p "$dest_dir"
      cp "$shipped" "$dest"
      echo "  [PARENT] installed $key from lib"
      current="$dest"
      continue
    fi

    if ! is_private_group "$gid"; then
      echo "  [PARENT] $key is public, left for Maven to download"
      break
    fi

    write_stub_pom "$gid" "$aid" "$ver" "$dest"
    echo "  [PARENT] stubbed $key"
    current="$dest"
  done
}

install_file() {
  local file="$1" gid="$2" aid="$3" ver="$4" packaging="$5" pom="${6:-}"
  local args=(
    -q -B install:install-file
    "-Dfile=$file"
    "-DgroupId=$gid"
    "-DartifactId=$aid"
    "-Dversion=$ver"
    "-Dpackaging=$packaging"
    "-Dmaven.repo.local=$MVN_REPO"
  )
  [[ -n "$pom" ]] && args+=("-DpomFile=$pom")

  local output
  if ! output="$(mvn "${args[@]}" 2>&1)"; then
    [[ -n "$output" ]] && sed 's/^/    /' <<< "$output"
    return 1
  fi
  return 0
}

COUNT=0
INSTALLED=0
SKIPPED=0
FAILED=0
PLUGIN_GROUPS=""
INSTALLED_POMS=()

shopt -s nullglob

for jar in lib/*.jar; do
  COUNT=$((COUNT + 1))

  if meta="$("$PY" "$HELPER" jarmeta "$jar" "$WORKDIR" | tr -d '\r')"; then
    IFS=$'\t' read -r GID AID VER PACKAGING IS_PLUGIN POM_FILE GOAL_PREFIX PLUGIN_NAME <<< "$meta"
  else
    # Not every jar carries META-INF/maven metadata (repackaged natives such as sigar do not).
    # Those need a sidecar lib/<jar base name>.pom spelling out the coordinates.
    sidecar="lib/$(basename "$jar" .jar).pom"
    if [[ ! -f "$sidecar" ]] || ! meta="$("$PY" "$HELPER" gav "$sidecar" | tr -d '\r')"; then
      echo "[MISS] $(basename "$jar") carries no META-INF/maven metadata."
      echo "       Add lib/$(basename "$jar" .jar).pom declaring its groupId/artifactId/version."
      FAILED=$((FAILED + 1))
      continue
    fi
    IFS=$'\t' read -r GID AID VER PACKAGING <<< "$meta"
    [[ "$PACKAGING" == "pom" ]] && PACKAGING="jar"
    IS_PLUGIN=0
    POM_FILE="$sidecar"
    GOAL_PREFIX=""
    PLUGIN_NAME=""
  fi

  COORD="$GID:$AID:$VER"
  DEST_DIR="$(artifact_dir "$GID" "$AID" "$VER")"
  DEST_JAR="$DEST_DIR/$AID-$VER.jar"
  DEST_POM="$DEST_DIR/$AID-$VER.pom"

  if [[ "$IS_PLUGIN" == "1" && -n "$GOAL_PREFIX" ]]; then
    case "$PLUGIN_GROUPS" in
      *"|$GID|"*) ;;
      *) PLUGIN_GROUPS="$PLUGIN_GROUPS|$GID|" ;;
    esac
    printf '%s\t%s\t%s\n' "$AID" "$GOAL_PREFIX" "$PLUGIN_NAME" >> "$WORKDIR/plugins-${GID}.tsv"
  fi

  USABLE=0
  if [[ -f "$DEST_JAR" ]] && is_locally_installed "$DEST_DIR" "$AID-$VER.jar"; then
    USABLE=1
  fi
  if [[ "$USABLE" == "1" && "$FORCE" != "1" ]]; then
    echo "[SKIP] $COORD"
    SKIPPED=$((SKIPPED + 1))
    # Still verify the ancestry: a previous run may have installed the jar but not its parents.
    if [[ -f "$DEST_POM" ]]; then
      install_parent_chain "$DEST_POM"
      INSTALLED_POMS+=("$DEST_POM")
    fi
    continue
  fi
  if [[ -f "$DEST_JAR" && "$USABLE" != "1" ]]; then
    echo "[RELINK] $COORD cached copy is bound to a remote repository, reinstalling"
  fi

  # An explicit lib/<artifactId>-<version>.pom wins over the one baked into the jar.
  if [[ -f "lib/$AID-$VER.pom" ]]; then
    POM_FILE="lib/$AID-$VER.pom"
  fi

  echo "[INSTALL] $COORD ($PACKAGING)  <- $(basename "$jar")"
  if ! install_file "$jar" "$GID" "$AID" "$VER" "$PACKAGING" "$POM_FILE"; then
    echo "[FAIL] $COORD"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ -f "$DEST_POM" ]]; then
    install_parent_chain "$DEST_POM"
    INSTALLED_POMS+=("$DEST_POM")
  fi
  INSTALLED=$((INSTALLED + 1))
done

# Standalone POMs (parents or BOMs that ship without a jar).
for pom in lib/*.pom; do
  base="$(basename "$pom" .pom)"
  [[ -f "lib/$base.jar" ]] && continue

  COUNT=$((COUNT + 1))
  if ! gav="$("$PY" "$HELPER" gav "$pom" | tr -d '\r')"; then
    echo "[MISS] cannot read GAV from $(basename "$pom")"
    FAILED=$((FAILED + 1))
    continue
  fi
  IFS=$'\t' read -r GID AID VER _PKG <<< "$gav"

  COORD="$GID:$AID:$VER"
  DEST_DIR="$(artifact_dir "$GID" "$AID" "$VER")"
  DEST="$DEST_DIR/$AID-$VER.pom"

  USABLE=0
  if [[ -f "$DEST" ]] && is_locally_installed "$DEST_DIR" "$AID-$VER.pom"; then
    USABLE=1
  fi
  if [[ "$USABLE" == "1" && "$FORCE" != "1" ]]; then
    echo "[SKIP] $COORD (pom)"
    SKIPPED=$((SKIPPED + 1))
    install_parent_chain "$DEST"
    continue
  fi
  if [[ -f "$DEST" && "$USABLE" != "1" ]]; then
    echo "[RELINK] $COORD cached copy is bound to a remote repository, reinstalling"
  fi

  echo "[INSTALL] $COORD (pom)  <- $(basename "$pom")"
  if ! install_file "$pom" "$GID" "$AID" "$VER" pom "$pom"; then
    echo "[FAIL] $COORD (pom)"
    FAILED=$((FAILED + 1))
    continue
  fi
  install_parent_chain "$DEST"
  INSTALLED_POMS+=("$DEST")
  INSTALLED=$((INSTALLED + 1))
done

# Report private dependencies that nothing provides. Public coordinates are skipped because
# Maven resolves those from its remote repositories on the next build.
SEEDS="$WORKDIR/verify-seeds.txt"
: > "$SEEDS"
for pom in "${INSTALLED_POMS[@]:-}"; do
  [[ -f "$pom" ]] && native_path "$pom" >> "$SEEDS"
done
mapfile -t missing_list < <("$PY" "$HELPER" missing "$MVN_REPO" "$PRIVATE_GROUPS" "$SEEDS" | tr -d '\r')

echo
echo "Done. files=$COUNT installed=$INSTALLED skipped=$SKIPPED failed=$FAILED"

if [[ "${#missing_list[@]}" -gt 0 ]]; then
  echo
  echo "[WARN] ${#missing_list[@]} private dependencies are referenced but not present in the repo."
  echo "       Add the matching jars to lib/ and re-run, or the build will fail to resolve them:"
  for m in "${missing_list[@]}"; do
    echo "       - $m"
  done
fi

if [[ -n "$PLUGIN_GROUPS" ]]; then
  mapfile -t plugin_list < <(tr '|' '\n' <<< "$PLUGIN_GROUPS" | grep -v '^$' | sort -u)
  echo
  for g in "${plugin_list[@]}"; do
    "$PY" "$HELPER" pluginmeta \
      "$LOCAL_REPO/${g//.//}/maven-metadata-local.xml" "$WORKDIR/plugins-${g}.tsv"
    echo "[PLUGINS] $g registered with prefixes: $(cut -f2 "$WORKDIR/plugins-${g}.tsv" | sort -u | paste -sd, - | sed 's/,/, /g')"
  done
  echo "          To use those prefixes outside this project, add to your settings.xml:"
  echo "            <pluginGroups>"
  for g in "${plugin_list[@]}"; do
    echo "              <pluginGroup>$g</pluginGroup>"
  done
  echo "            </pluginGroups>"
fi

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
