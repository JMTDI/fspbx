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

# ── Clear any stale/broken ESL ini files before we begin ───────────────────
# (prevents PHP startup warnings during the build phase)
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

# ── Build ESL from source (ARM64 / aarch64) ─────────────────────────────────
build_esl_from_source() {
  print_info "ARM64 detected — building ESL PHP extension from source..."

  # NOTE: libfreeswitch-dev is NOT in Debian ARM64 repos (SignalWire x86 only).
  # The ESL build is self-contained inside the FreeSWITCH source tree — we
  # only need the generic build tools + php8.4-dev + swig.
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php8.4-dev \
    swig \
    build-essential \
    git \
    ca-certificates \
    libtool \
    automake \
    autoconf

  # ── Locate or clone FreeSWITCH source ──────────────────────────────────
  FS_SRC=""
  for candidate in /usr/src/freeswitch /usr/src/freeswitch-*; do
    if [ -d "$candidate/libs/esl" ]; then
      FS_SRC="$candidate"
      print_info "Found existing FreeSWITCH source at: $FS_SRC"
      break
    fi
  done

  if [ -z "$FS_SRC" ]; then
    print_warn "FreeSWITCH source not found — cloning (shallow, main branch)..."
    git clone --depth=1 https://github.com/signalwire/freeswitch.git /usr/src/freeswitch
    FS_SRC="/usr/src/freeswitch"
    cd "$FS_SRC"
    print_info "Running bootstrap..."
    ./bootstrap.sh -j
  fi

  ESL_DIR="$FS_SRC/libs/esl"
  if [ ! -d "$ESL_DIR" ]; then
    print_error "ESL directory not found in FreeSWITCH source: $ESL_DIR"
    exit 1
  fi

  print_info "Building ESL PHP module (make phpmod) in $ESL_DIR ..."
  cd "$ESL_DIR"

  # Clean any previous partial build
  make clean 2>/dev/null || true
  make phpmod

  # ── Locate the built .so ────────────────────────────────────────────────
  BUILT_SO=""
  for candidate in \
      "$ESL_DIR/php8/esl.so" \
      "$ESL_DIR/php/esl.so" \
      "$ESL_DIR/.libs/esl.so"; do
    if [ -f "$candidate" ]; then
      BUILT_SO="$candidate"
      break
    fi
  done

  if [ -z "$BUILT_SO" ]; then
    print_error "Build finished but esl.so not found. Searched:"
    print_error "  $ESL_DIR/php8/esl.so"
    print_error "  $ESL_DIR/php/esl.so"
    print_error "  $ESL_DIR/.libs/esl.so"
    print_error "Contents of $ESL_DIR:"
    ls -la "$ESL_DIR" || true
    exit 1
  fi

  print_info "Found built module: $BUILT_SO"

  # ── Arch verification ───────────────────────────────────────────────────
  SO_FILE_OUTPUT="$(file "$BUILT_SO")"
  print_info "Built binary: $SO_FILE_OUTPUT"
  case "$SO_FILE_OUTPUT" in
    *aarch64*|*ARM\ aarch64*)
      print_success "Architecture verified: aarch64 ✓" ;;
    *)
      print_error "Built .so does not appear to be aarch64: $SO_FILE_OUTPUT"
      exit 1 ;;
  esac

  # ── Dependency check ────────────────────────────────────────────────────
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
