#!/bin/sh
set -eu

print_success() { printf "\033[32m%s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m%s\033[0m\n" "$1"; }
print_warn()    { printf "\033[33m%s\033[0m\n" "$1"; }
print_info()    { printf "\033[36m%s\033[0m\n" "$1"; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
  print_error "Run as root: sudo sh $0"
  exit 1
fi

PHP_BIN="/usr/bin/php8.4"
PHP_CONFIG="/usr/bin/php-config8.4"
FPM_SERVICE="php8.4-fpm"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ESL_SO_SRC="${SCRIPT_DIR}/esl-8.4.so"
FS_SRC="/usr/src/freeswitch"

ARCH="$(uname -m)"
print_info "Detected architecture: $ARCH"

if [ ! -x "$PHP_BIN" ]; then
  print_error "php8.4 not found at $PHP_BIN"
  exit 1
fi

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

detect_swig_php_flag() {
  SWIG_VER="#(swig -version 2>&1 | awk '/SWIG Version/{print $3}')";
  print_info "Detected SWIG version: $SWIG_VER";
  SWIG_MAJOR="$(printf '%s' "$SWIG_VER" | cut -d. -f1)";
  SWIG_MINOR="$(printf '%s' "$SWIG_VER" | cut -d. -f2)";
  if [ "$SWIG_MAJOR" -gt 4 ] || { [ "$SWIG_MAJOR" -eq 4 ] && [ "$SWIG_MINOR" -ge 1 ]; }; then
    SWIG_PHP_FLAG="-php";
    print_info "Using SWIG flag: -php  (SWIG >= 4.1)";
  else
    SWIG_PHP_FLAG="-php8";
    print_info "Using SWIG flag: -php8  (SWIG < 4.1)";
  fi
}

ensure_freeswitch_source() {
  ESL_DIR="$FS_SRC/libs/esl";
  ESL_INC_DIR="$ESL_DIR/src/include";
  HEADERS_OK=true;
  for f in "$ESL_DIR/ESL.i" "$ESL_INC_DIR/esl_oop.h" "$ESL_INC_DIR/esl.h"; do
    [ -f "$f" ] || HEADERS_OK=false;
  done;
  if [ "$HEADERS_OK" = false ]; then
    if [ -d "$FS_SRC" ]; then
      print_warn "FreeSWITCH source incomplete -- removing and re-cloning...";
      rm -rf "$FS_SRC";
    else
      print_info "Cloning FreeSWITCH source...";
    fi;
    git clone --depth=1 --recurse-submodules --shallow-submodules \
      https://github.com/signalwire/freeswitch.git "$FS_SRC";
  else
    print_info "FreeSWITCH source OK at: $FS_SRC";
    return;
  fi;
  for f in "$ESL_DIR/ESL.i" "$ESL_INC_DIR/esl_oop.h" "$ESL_INC_DIR/esl.h"; do
    if [ ! -f "$f" ]; then
      print_error "Required file still missing after clone: $f";
      exit 1;
    fi;
  done;
  print_success "All required ESL source files verified."
}

build_esl_from_source() {
  print_info "ARM64 detected -- building ESL PHP extension from source...";

  apt-get update -qq;
  apt-get install -y --no-install-recommends \
    php8.4-dev swig build-essential git ca-certificates \
    libxml2-dev libz-dev libsodium-dev libargon2-dev;

  detect_swig_php_flag;
  ensure_freeswitch_source;

  ESL_DIR="$FS_SRC/libs/esl";
  ESL_SRC_DIR="$ESL_DIR/src";
  ESL_INC_DIR="$ESL_SRC_DIR/include";
  PHP_EXT_DIR="$ESL_DIR/php";

  if [ ! -d "$PHP_EXT_DIR" ]; then
    print_error "PHP extension dir not found: $PHP_EXT_DIR";
    ls -la "$ESL_DIR" || true;
    exit 1;
  fi;

  print_info "Regenerating SWIG bindings...";
  cd "$ESL_DIR";
  swig "$SWIG_PHP_FLAG" -c++ -module esl -cppext cpp \
       -I"$ESL_DIR" -I"$ESL_SRC_DIR" -I"$ESL_INC_DIR" \
       -o "$PHP_EXT_DIR/ESL.cpp" -outdir "$PHP_EXT_DIR" \
       "$ESL_DIR/ESL.i";
  print_success "SWIG bindings generated."

  # Get PHP include flags only (not --ldflags/--libs which pull in unneeded system libs)
  PHP_INCLUDES="$($PHP_CONFIG --includes)";

  mkdir -p "$PHP_EXT_DIR/modules";

  # Step 1: Compile ESL.cpp -> ESL.o
  print_info "Compiling ESL.cpp...";
  c++ -fPIC \
      -I"$ESL_DIR" -I"$ESL_SRC_DIR" -I"$ESL_INC_DIR" \
      $PHP_INCLUDES \
      -DHAVE_CONFIG_H -DZEND_COMPILE_DL_EXT=1 \
      -c "$PHP_EXT_DIR/ESL.cpp" \
      -o "$PHP_EXT_DIR/ESL.o";
  print_success "Compiled ESL.o";

  # Step 2: Link into a shared PHP extension.
  # PHP extensions must NOT be linked against libphp or the PHP libs themselves --
  # they are loaded into an existing PHP process at runtime.  We only need to
  # resolve symbols that ESL.cpp itself uses directly (none beyond libc/libstdc++
  # which the linker picks up automatically).
  print_info "Linking esl.so...";
  c++ -shared -fPIC \
      -o "$PHP_EXT_DIR/modules/esl.so" \
      "$PHP_EXT_DIR/ESL.o";
  print_success "Linked esl.so";

  BUILT_SO="$PHP_EXT_DIR/modules/esl.so";

  if [ ! -f "$BUILT_SO" ]; then
    print_error "Build finished but esl.so not found.";
    ls -la "$PHP_EXT_DIR/modules/" 2>/dev/null || true;
    exit 1;
  fi;

  print_info "Found built module: $BUILT_SO";

  SO_FILE_OUTPUT="$(file "$BUILT_SO")";
  print_info "Built binary info: $SO_FILE_OUTPUT";
  case "$SO_FILE_OUTPUT" in
    *aarch64*|*ARM\ aarch64*) print_success "Architecture verified: aarch64" ;; 
    *) print_error "Built .so does not appear to be aarch64: $SO_FILE_OUTPUT"; exit 1 ;;
  esac

  if ldd "$BUILT_SO" 2>&1 | grep -q "not found"; then
    print_error "Missing shared library dependencies:";
    ldd "$BUILT_SO" | grep "not found";
    exit 1;
  fi;
  print_success "ldd check passed -- no missing dependencies."

  ESL_SO_SRC="$BUILT_SO";
}

case "$ARCH" in
  aarch64|arm64)
    build_esl_from_source;
    ;;
  x86_64|amd64)
    if [ ! -f "$ESL_SO_SRC" ]; then
      print_error "Missing ESL module: $ESL_SO_SRC";
      print_error "Place your compiled module at: /var/www/fspbx/install/esl-8.4.so";
      exit 1;
    fi;
    SO_FILE_OUTPUT="$(file "$ESL_SO_SRC")";
    case "$SO_FILE_OUTPUT" in
      *x86-64*|*x86_64*) print_success "Pre-built binary architecture verified: x86_64" ;; 
      *) print_error "Pre-built .so is not x86_64: $SO_FILE_OUTPUT"; exit 1 ;;
    esac
    ;;
  *)
    print_error "Unsupported architecture: $ARCH";
    exit 1 ;;
 esac

install -m 0644 -o root -g root "$ESL_SO_SRC" "$EXTENSION_DIR/esl.so";
print_success "Installed: $EXTENSION_DIR/esl.so"

CLI_INI_DIR="/etc/php/8.4/cli/conf.d";
FPM_INI_DIR="/etc/php/8.4/fpm/conf.d";
mkdir -p "$CLI_INI_DIR" "$FPM_INI_DIR";
echo "extension=esl.so" > "$CLI_INI_DIR/30-esl.ini";
echo "extension=esl.so" > "$FPM_INI_DIR/30-esl.ini";
print_success "Enabled ESL in $CLI_INI_DIR/30-esl.ini and $FPM_INI_DIR/30-esl.ini"

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart "$FPM_SERVICE";
else
  service "$FPM_SERVICE" restart;
fi
print_success "Restarted: $FPM_SERVICE"

if "$PHP_BIN" -m | grep -qi '^esl$'; then
  print_success "ESL loaded in PHP 8.4 (CLI).";
else
  print_error "ESL did not load in PHP 8.4.";
  print_warn "Check: ldd \"$EXTENSION_DIR/esl.so\"";
  exit 1;
fi

print_success "ESL installation completed successfully for PHP 8.4 on $ARCH.",