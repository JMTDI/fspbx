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

EXTENSION_DIR="$("$PHP_BIN" -r 'echo ini_get("extension_dir");')"
if [ -z "$EXTENSION_DIR" ]; then
  print_error "Failed to detect PHP 8.4 extension_dir."
  exit 1
fi
print_success "PHP 8.4 extension_dir: $EXTENSION_DIR"

# ── Detect correct SWIG PHP flag based on installed version ─────────────────
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
    autoconf

  detect_swig_php_flag

  # ── Clone FreeSWITCH source ─────────────────────────────────────────────
  # NOTE: Do NOT use sparse checkout — ESL.i references headers across
  # libs/esl/ and a partial tree causes "Unable to find 'esl_oop.h'" errors.
  if [ ! -d "$FS_SRC/libs/esl" ]; then
    print_info "Cloning FreeSWITCH source (shallow)..."
    git clone --depth=1 https://github.com/signalwire/freeswitch.git "$FS_SRC"
  else
    print_info "Found existing FreeSWITCH source at: $FS_SRC"

    # If this was a previous sparse checkout, it may be missing files.
    # Check for the header that SWIG needs and fetch if absent.
    if [ ! -f "$FS_SRC/libs/esl/esl_oop.h" ]; then
      print_warn "esl_oop.h missing — previous sparse checkout detected."
      print_info "Fetching full libs/esl tree..."
      cd "$FS_SRC"
      # Disable sparse checkout so git pulls everything
      git sparse-checkout disable 2>/dev/null || true
      git config core.sparseCheckout false 2>/dev/null || true
      git checkout HEAD -- libs/esl
    fi
  fi

  ESL_DIR="$FS_SRC/libs/esl"
  PHP_EXT_DIR="$ESL_DIR/php"

  # Verify all required headers are present
  for required in "$ESL_DIR/ESL.i" "$ESL_DIR/esl_oop.h" "$ESL_DIR/esl.h"; do
    if [ ! -f "$required" ]; then
      print_error "Required file missing: $required"
      print_error "Contents of $ESL_DIR:"
      ls -la "$ESL_DIR" || true
      exit 1
    fi
  done
  print_success "All required ESL headers found."

  if [ ! -d "$PHP_EXT_DIR" ]; then
    print_error "Expected ESL PHP dir not found: $PHP_EXT_DIR"
    print_error "Contents of $ESL_DIR:"
    ls -la "$ESL_DIR" || true
    exit 1
  fi

  # ── Regenerate SWIG bindings ────────────────────────────────────────────
  # Run from ESL_DIR so SWIG resolves relative #include paths correctly.
  # -I"$ESL_DIR" makes headers like esl_oop.h findable explicitly.
  print_info "Regenerating SWIG bindings (from $ESL_DIR)..."
  cd "$ESL_DIR"
  swig "$SWIG_PHP_FLAG" \
       -cppext cpp \
       -I"$ESL_DIR" \
       -o "$PHP_EXT_DIR/ESL.cpp" \
       -outdir "$PHP_EXT_DIR" \
       "$ESL_DIR/ESL.i"
  print_success "SWIG bindings generated."

  # ── Build using phpize ──────────────────────────────────────────────────
  print_info "Running phpize in $PHP_EXT_DIR ..."
  cd "$PHP_EXT_DIR"

  if [ -f Makefile ]; then
    make distclean 2>/dev/null || make clean 2>/dev/null || true
  fi
  "$PHPIZE" --clean 2>/dev/null || true
  "$PHPIZE"

  print_info "Running configure..."
  ./configure --with-php-config="$PHP_CONFIG"

  print_info "Running make..."
  make -j"$(nproc)"

  # ── Locate the built .so ────────────────────────────────────────────────
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
    print_error "Contents of $PHP_EXT_DIR:"
    ls -la "$PHP_EXT_DIR/" || true
    print_error "Contents of modules/ (if exists):"
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
