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
FPM_SERVICE="php8.4-fpm"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ESL_SO_SRC="${SCRIPT_DIR}/esl-8.4.so"

# ── Detect architecture ─────────────────────────────────────────────────────
ARCH="$(uname -m)"
print_info "Detected architecture: $ARCH"

if [ ! -x "$PHP_BIN" ]; then
  print_error "php8.4 not found at $PHP_BIN"
  exit 1
fi

EXTENSION_DIR="$("$PHP_BIN" -r 'echo ini_get("extension_dir");')"
if [ -z "$EXTENSION_DIR" ]; then
  print_error "Failed to detect PHP 8.4 extension_dir."
  exit 1
fi
print_success "PHP 8.4 extension_dir: $EXTENSION_DIR"

# ── Build ESL from source (ARM64 / aarch64) ─────────────────────────────────
build_esl_from_source() {
  print_info "ARM64 detected — building ESL PHP extension from source..."

  # Install build dependencies
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php8.4-dev \
    swig \
    build-essential \
    git \
    libfreeswitch-dev \
    ca-certificates

  # Locate or clone FreeSWITCH source
  FS_SRC=""
  for candidate in /usr/src/freeswitch /usr/src/freeswitch-*; do
    if [ -d "$candidate/libs/esl" ]; then
      FS_SRC="$candidate"
      break
    fi
  done

  if [ -z "$FS_SRC" ]; then
    print_warn "FreeSWITCH source not found — cloning (shallow)..."
    git clone --depth=1 https://github.com/signalwire/freeswitch.git /usr/src/freeswitch
    FS_SRC="/usr/src/freeswitch"
    cd "$FS_SRC"
    ./bootstrap.sh -j
  fi

  print_info "Building ESL PHP module in $FS_SRC/libs/esl ..."
  cd "$FS_SRC/libs/esl"
  make phpmod

  # Confirm the built .so is actually aarch64
  BUILT_SO="$FS_SRC/libs/esl/php8/esl.so"
  if [ ! -f "$BUILT_SO" ]; then
    print_error "Build completed but esl.so not found at: $BUILT_SO"
    exit 1
  fi

  SO_ARCH="$(file "$BUILT_SO")"
  print_info "Built binary: $SO_ARCH"
  case "$SO_ARCH" in
    *aarch64*|*ARM*) print_success "Architecture verified: aarch64 ✓" ;;
    *)
      print_error "Built .so does not appear to be aarch64: $SO_ARCH"
      exit 1
      ;;
  esac

  # Verify shared library dependencies before deploying
  if ! ldd "$BUILT_SO" | grep -q "not found"; then
    print_success "ldd check passed — no missing dependencies."
  else
    print_error "Missing shared library dependencies:"
    ldd "$BUILT_SO" | grep "not found"
    exit 1
  fi

  ESL_SO_SRC="$BUILT_SO"
}

# ── Decide: use pre-built or build from source ───────────────────────────────
case "$ARCH" in
  aarch64|arm64)
    # Ignore any pre-built x86_64 binary and always build natively
    build_esl_from_source
    ;;
  x86_64|amd64)
    # Use the pre-built binary as before
    if [ ! -f "$ESL_SO_SRC" ]; then
      print_error "Missing ESL module: $ESL_SO_SRC"
      print_error "Place your compiled module at: /var/www/fspbx/install/esl-8.4.so"
      exit 1
    fi
    # Verify the pre-built binary is actually x86_64
    SO_ARCH="$(file "$ESL_SO_SRC")"
    case "$SO_ARCH" in
      *x86-64*|*x86_64*) print_success "Pre-built binary architecture verified: x86_64 ✓" ;;
      *)
        print_error "Pre-built .so does not appear to be x86_64: $SO_ARCH"
        print_error "You may be running x86_64 but have an incompatible binary."
        exit 1
        ;;
    esac
    ;;
  *)
    print_error "Unsupported architecture: $ARCH"
    print_error "Only x86_64 (pre-built) and aarch64 (source build) are supported."
    exit 1
    ;;
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
