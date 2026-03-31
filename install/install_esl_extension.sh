#!/bin/sh
set -eu

print_success() { printf "\033[32m%s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m%s\033[0m\n" "$1"; }
print_warn()    { printf "\033[33m%s\033[0m\n" "$1"; }
print_info()    { printf "\033[36m%s\033[0m\n" "$1"; }

# ── Must be root ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  print_error "Run as root: sudo sh $0"
  exit 1
fi

PHP_BIN="/usr/bin/php8.4"
PHP_CONFIG="/usr/bin/php-config8.4"
PHPIZE="/usr/bin/phpize8.4"
FPM_SERVICE="php8.4-fpm"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ESL_SO_SRC="${SCRIPT_DIR}/esl-8.4.so"
FS_SRC="/usr/src/freeswitch"

# ── Detect architecture ─────────────────────────────────────────────────────
ARCH="$(uname -m)"
print_info "Detected architecture: $ARCH"

if [ ! -x "$PHP_BIN" ]; then
  print_error "php8.4 not found at $PHP_BIN"
  exit 1
fi

# ── Clear any stale/broken ESL ini files before we begin ───────────────────
for ini in \
    /etc/php/8.4/cli/conf.d/30-esl.ini \
    /etc/php/8.4/fpm/conf.d/30-esl.ini; do
  [ -f "$ini" ] && rm -f "$ini" && print_info "Removed stale: $ini"
done

EXTENSION_DIR="$($PHP_BIN -r 'echo ini_get("extension_dir");')"
if [ -z "$EXTENSION_DIR" ]; then
  print_error "Failed to detect PHP 8.4 extension_dir."
  exit 1
fi
print_success "PHP 8.4 extension_dir: $EXTENSION_DIR"

# ── Detect correct SWIG PHP flag ─────────────────────────────────────────────
detect_swig_php_flag() {
  SWIG_VER="$(swig -version 2>&1 | awk '/SWIG Version/{print $3}')"
  print_info "Detected SWIG version: $SWIG_VER"
  SWIG_MAJOR="$(printf '%s' "$SWIG_VER" | cut -d. -f1)"
  SWIG_MINOR="$(printf '%s' "$SWIG_VER" | cut -d. -f2)"
  if [ "$SWIG_MAJOR" -gt 4 ] || { [ "$SWIG_MAJOR" -eq 4 ] && [ "$SWIG_MINOR" -ge 1 ]; }; then
    SWIG_PHP_FLAG="-php"
    print_info "Using SWIG flag: -php  (SWIG >= 4.1)"
  else
    SWIG_PHP_FLAG="-php8"
    print_info "Using SWIG flag: -php8  (SWIG < 4.1)"
  fi
}

# ── Ensure a complete FreeSWITCH clone ──────────────────────────────────────
# Header layout:
#   libs/esl/ESL.i
#   libs/esl/src/include/esl_oop.h   (confirmed from directory listing)
#   libs/esl/src/include/esl.h
ensure_freeswitch_source() {
  ESL_DIR="$FS_SRC/libs/esl"
  ESL_INC_DIR="$ESL_DIR/src/include"

  HEADERS_OK=true
  for f in "$ESL_DIR/ESL.i" "$ESL_INC_DIR/esl_oop.h" "$ESL_INC_DIR/esl.h"; do
    [ -f "$f" ] || HEADERS_OK=false
  done

  if [ "$HEADERS_OK" = false ]; then
    if [ -d "$FS_SRC" ]; then
      print_warn "FreeSWITCH source incomplete — removing and re-cloning..."
      rm -rf "$FS_SRC"
    else
      print_info "Cloning FreeSWITCH source..."
    fi

    git clone \
      --depth=1 \
      --recurse-submodules \
      --shallow-submodules \
      https://github.com/signalwire/freeswitch.git "$FS_SRC"
  else
    print_info "FreeSWITCH source OK at: $FS_SRC"
    return
  fi

  # Post-clone sanity check
  for f in "$ESL_DIR/ESL.i" "$ESL_INC_DIR/esl_oop.h" "$ESL_INC_DIR/esl.h"; do
    if [ ! -f "$f" ]; then
      print_error "Required file still missing after clone: $f"
      print_error "── $ESL_DIR:"
      ls -la "$ESL_DIR"            2>/dev/null || true
      print_error "── $ESL_DIR/src:"
      ls -la "$ESL_DIR/src"        2>/dev/null || true
      print_error "── $ESL_INC_DIR:"
      ls -la "$ESL_INC_DIR"        2>/dev/null || print_error "  (does not exist)"
      exit 1
    fi
  done
  print_success "All required ESL source files verified."
}

# ── Build ESL from source (ARM64 / aarch64) ─────────────────────────────────
build_esl_from_source() {
  print_info "ARM64 detected — building ESL PHP extension from source..."

  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php8.4-dev \
    swig \
    build-essential \
    git \
    ca-certificates \
    autoconf \
    libtool

  detect_swig_php_flag
  ensure_freeswitch_source

  ESL_DIR="$FS_SRC/libs/esl"
  ESL_SRC_DIR="$ESL_DIR/src"
  ESL_INC_DIR="$ESL_SRC_DIR/include"
  PHP_EXT_DIR="$ESL_DIR/php"

  if [ ! -d "$PHP_EXT_DIR" ]; then
    print_error "PHP extension dir not found: $PHP_EXT_DIR"
    ls -la "$ESL_DIR" || true
    exit 1
  fi

  # ── Regenerate SWIG bindings ────────────────────────────────────────────
  # -c++        : parse in C++ mode — required because esl_oop.h uses 'class'
  # -module esl : ESL.i has no %module directive; we must supply the name
  # -cppext cpp : output file gets .cpp extension (not .cxx)
  # -I flags    : cover all three header locations
  print_info "Regenerating SWIG bindings..."
  cd "$ESL_DIR"
  swig "$SWIG_PHP_FLAG" \
       -c++ \
       -module esl \
       -cppext cpp \
       -I"$ESL_DIR" \
       -I"$ESL_SRC_DIR" \
       -I"$ESL_INC_DIR" \
       -o "$PHP_EXT_DIR/ESL.cpp" \
       -outdir "$PHP_EXT_DIR" \
       "$ESL_DIR/ESL.i"
  print_success "SWIG bindings generated."

  # ── Generate config.m4 if missing (phpize requires it) ─────────────────
  if [ ! -f "$PHP_EXT_DIR/config.m4" ]; then
    print_info "Generating config.m4 for ESL PHP extension..."
    cat > "$PHP_EXT_DIR/config.m4" <<'EOF'
PHP_ARG_ENABLE(esl, whether to enable ESL support,
[  --enable-esl            Enable ESL support])

if test "$PHP_ESL" != "no"; then
  PHP_NEW_EXTENSION(esl, ESL.cpp, $ext_shared)
fi
EOF
    print_success "config.m4 generated."
  fi

  # ── Build using phpize ──────────────────────────────────────────────────
  print_info "Running phpize in $PHP_EXT_DIR ..."
  cd "$PHP_EXT_DIR"

  if [ -f Makefile ]; then
    make distclean 2>/dev/null || make clean 2>/dev/null || true
  fi
  "$PHPIZE" --clean 2>/dev/null || true

  # Remove stale libtool artifacts from the FreeSWITCH build system.
  # These will be regenerated correctly by libtoolize + phpize below.
  rm -f libtool ltmain.sh aclocal.m4

  "$PHPIZE"

  # Run libtoolize --force so configure receives a fresh ltmain.sh and a
  # libtool wrapper that understands --tag=CXX (required for C++ compilation).
  # Without this, configure regenerates the libtool script from the stale
  # FreeSWITCH-bundled ltmain.sh, which predates --tag=CXX support.
  libtoolize --force --copy 2>/dev/null || true

  print_info "Running configure..."
  CPPFLAGS="-I$ESL_DIR -I$ESL_SRC_DIR -I$ESL_INC_DIR" \
    ./configure --with-php-config="$PHP_CONFIG"

  # Re-run libtoolize after configure in case configure regenerated libtool
  # from the bundled ltmain.sh again — this ensures the final wrapper is
  # the system libtool that supports --tag=CXX.
  libtoolize --force --copy 2>/dev/null || true

  print_info "Running make..."
  make -j"$(nproc)"

  # ── Locate the built .so ──────────────��─────────────────────────────────
  BUILT_SO=""
  for candidate in \
      "$PHP_EXT_DIR/modules/esl.so" \
      "$PHP_EXT_DIR/.libs/esl.so"; do
    if [ -f "$candidate" ]; then
      BUILT_SO="$candidate"
      break
    fi
  done

  if [ -z "$BUILT_SO" ]; then
    print_error "Build finished but esl.so not found. Searched:"
    print_error "  $PHP_EXT_DIR/modules/esl.so"
    print_error "  $PHP_EXT_DIR/.libs/esl.so"
    print_error "── $PHP_EXT_DIR:"
    ls -la "$PHP_EXT_DIR/" || true
    print_error "── $PHP_EXT_DIR/modules (if exists):"
    ls -la "$PHP_EXT_DIR/modules/" 2>/dev/null || true
    exit 1
  fi

  print_info "Found built module: $BUILT_SO"

  # ── Arch + dependency verification ─────────────────────────────────────
  SO_FILE_OUTPUT="$(file "$BUILT_SO")"
  print_info "Built binary info: $SO_FILE_OUTPUT"
  case "$SO_FILE_OUTPUT" in
    *aarch64*|*ARM\ aarch64*)
      print_success "Architecture verified: aarch64 ✓" ;;
    *)
      print_error "Built .so does not appear to be aarch64: $SO_FILE_OUTPUT"
      exit 1 ;;
  esac

  if ldd "$BUILT_SO" 2>&1 | grep -q "not found"; then
    print_error "Missing shared library dependencies:"
    ldd "$BUILT_SO" | grep "not found"
    exit 1
  fi
  print_success "ldd check passed — no missing dependencies."

  ESL_SO_SRC="$BUILT_SO"
}

# ── Decide: use pre-built or build from source ───────────────────────────────
case "$ARCH" in
  aarch64|arm64)
    build_esl_from_source
    ;;
  x86_64|amd64)
    if [ ! -f "$ESL_SO_SRC" ]; then
      print_error "Missing ESL module: $ESL_SO_SRC"
      print_error "Place your compiled module at: /var/www/fspbx/install/esl-8.4.so"
      exit 1
    fi
    SO_FILE_OUTPUT="$(file "$ESL_SO_SRC")"
    case "$SO_FILE_OUTPUT" in
      *x86-64*|*x86_64*)
        print_success "Pre-built binary architecture verified: x86_64 ✓" ;;
      *)
        print_error "Pre-built .so is not x86_64: $SO_FILE_OUTPUT"
        exit 1 ;;
    esac
    ;;
  *)
    print_error "Unsupported architecture: $ARCH"
    exit 1 ;;
esac

# ── Install the .so ──────────────────────────────────────────────────────────
install -m 0644 -o root -g root "$ESL_SO_SRC" "$EXTENSION_DIR/esl.so"
print_success "Installed: $EXTENSION_DIR/esl.so"

# ── Enable extension for CLI + FPM ──────────────────────────────────────────
CLI_INI_DIR="/etc/php/8.4/cli/conf.d"
FPM_INI_DIR="/etc/php/8.4/fpm/conf.d"
mkdir -p "$CLI_INI_DIR" "$FPM_INI_DIR"
echo "extension=esl.so" > "$CLI_INI_DIR/30-esl.ini"
echo "extension=esl.so" > "$FPM_INI_DIR/30-esl.ini"
print_success "Enabled ESL in:"
print_success "  $CLI_INI_DIR/30-esl.ini"
print_success "  $FPM_INI_DIR/30-esl.ini"

# ── Restart FPM ─────────────────────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart "$FPM_SERVICE"
else
  service "$FPM_SERVICE" restart
fi
print_success "Restarted: $FPM_SERVICE"

# ── Verify module loads ──────────────────────────────────────────────────────
if "$PHP_BIN" -m | grep -qi '^esl$'; then
  print_success "✅ ESL loaded in PHP 8.4 (CLI)."
else
  print_error "❌ ESL did not load in PHP 8.4."
  print_warn "Check dependencies with:"
  print_warn "  ldd \"$EXTENSION_DIR/esl.so\""
  exit 1
fi

print_success "🎉 ESL installation completed successfully for PHP 8.4 on $ARCH."