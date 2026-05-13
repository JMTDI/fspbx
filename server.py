#!/usr/bin/env python3
"""
server.py — Full FS PBX installer for Debian 12 (bookworm) / Debian 13 (trixie).
Equivalent to:  wget -O- https://raw.githubusercontent.com/nemerald-voip/fspbx/main/install/install-fspbx.sh | bash

Usage:
    sudo python3 server.py            # full install
    sudo python3 server.py --help
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import urllib.request
from datetime import datetime
from pathlib import Path

# ──────────────────────────────────────────────────────────────────────────────
# Colour helpers
# ──────────────────────────────────────────────────────────────────────────────
GREEN  = "\033[32m"
RED    = "\033[31m"
YELLOW = "\033[33m"
RESET  = "\033[0m"

def ok(msg):   print(f"{GREEN}{msg}{RESET}", flush=True)
def err(msg):  print(f"{RED}{msg}{RESET}",   file=sys.stderr, flush=True)
def warn(msg): print(f"{YELLOW}{msg}{RESET}", flush=True)

def die(msg):
    err(msg)
    sys.exit(1)

# ──────────────────────────────────────────────────────────────────────────────
# Shell helpers
# ──────────────────────────────────────────────────────────────────────────────
def run(cmd, *, check=True, env=None, cwd=None, shell=False):
    """Run a command, streaming output.  Raises on non-zero exit unless check=False."""
    merged_env = {**os.environ, **(env or {})}
    result = subprocess.run(
        cmd,
        shell=shell,
        check=check,
        env=merged_env,
        cwd=cwd,
    )
    return result

def bash(script_path, *, env=None, cwd="/var/www/fspbx"):
    """Execute a bash script from the install/ directory."""
    ok(f"Running {script_path} ...")
    run(["bash", str(script_path)], env=env, cwd=cwd)

def apt_install(*packages):
    run(["apt-get", "install", "-y", "--no-install-recommends", *packages],
        env={"DEBIAN_FRONTEND": "noninteractive"})

# ──────────────────────────────────────────────────────────────────────────────
# OS detection
# ──────────────────────────────────────────────────────────────────────────────
def get_os_codename():
    try:
        r = subprocess.run(["lsb_release", "-sc"], capture_output=True, text=True)
        return r.stdout.strip()
    except FileNotFoundError:
        return ""

def get_pg_version(codename):
    return {"bookworm": "17", "trixie": "18"}.get(codename, "17")

def get_external_ip():
    try:
        with urllib.request.urlopen("http://checkip.amazonaws.com", timeout=10) as r:
            return r.read().decode().strip()
    except Exception:
        warn("Could not fetch external IP; defaulting to 127.0.0.1")
        return "127.0.0.1"

# ──────────────────────────────────────────────────────────────────────────────
# Step helpers
# ──────────────────────────────────────────────────────────────────────────────
def ensure_base_tools():
    """Ensure git, curl, sudo are present (mirrors install-fspbx.sh top block)."""
    for pkg in ("git", "curl", "sudo"):
        if not shutil.which(pkg):
            ok(f"Installing {pkg}...")
            run(["apt-get", "update", "-y"])
            apt_install(pkg)
            ok(f"{pkg} installed.")

def fetch_fusionpbx_version():
    ok("Fetching latest FusionPBX release version...")
    url = "https://api.github.com/repos/nemerald-voip/fusionpbx/releases/latest"
    req = urllib.request.Request(url, headers={"User-Agent": "fspbx-installer"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read().decode()
    m = re.search(r'"tag_name"\s*:\s*"([^"]+)"', data)
    if not m:
        die("Failed to fetch FusionPBX version.")
    version = m.group(1)
    ok(f"Latest FusionPBX version: {version}")
    return version

def clone_fspbx(install_dir: Path):
    if install_dir.exists() and any(install_dir.iterdir()):
        backup = Path(f"/var/www/fspbx_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        ok(f"Backing up existing installation to {backup} ...")
        shutil.move(str(install_dir), str(backup))
        ok(f"Backup completed: {backup}")
    ok("Cloning FS PBX repository...")
    run(["git", "clone", "--depth", "1",
         "https://github.com/JMTDI/fspbx.git", str(install_dir)])
    ok("FS PBX repository cloned successfully.")

def download_fusionpbx(install_dir: Path, version: str):
    public_dir = install_dir / "public"
    public_dir.mkdir(parents=True, exist_ok=True)
    tarball = public_dir / f"fusionpbx-{version}.tar.gz"
    url = f"https://github.com/nemerald-voip/fusionpbx/archive/refs/tags/{version}.tar.gz"
    ok(f"Downloading FusionPBX {version} ...")
    urllib.request.urlretrieve(url, tarball)
    ok("Extracting FusionPBX files...")
    with tarfile.open(tarball, "r:gz") as tf:
        members = tf.getmembers()
        # strip top-level directory component
        prefix = members[0].name.split("/")[0] + "/"
        for m in members:
            m.name = m.name[len(prefix):]
            if m.name:
                tf.extract(m, path=public_dir)
    tarball.unlink()
    ok(f"FusionPBX {version} extracted successfully.")

def setup_env_file(install_dir: Path, db_name: str, db_user: str, db_pass: str, external_ip: str):
    env_example = install_dir / ".env.example"
    env_file    = install_dir / ".env"
    if not env_file.exists():
        shutil.copy(env_example, env_file)
        ok(".env created from .env.example")

    replacements = {
        r"^DB_DATABASE=.*":              f"DB_DATABASE={db_name}",
        r"^DB_USERNAME=.*":              f"DB_USERNAME={db_user}",
        r"^DB_PASSWORD=.*":              f"DB_PASSWORD={db_pass}",
        r"^APP_URL=.*":                  f"APP_URL=https://{external_ip}",
        r"^SESSION_DOMAIN=.*":           f"SESSION_DOMAIN={external_ip}",
        r"^SANCTUM_STATEFUL_DOMAINS=.*": f"SANCTUM_STATEFUL_DOMAINS={external_ip}",
    }
    content = env_file.read_text()
    for pattern, replacement in replacements.items():
        content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
    env_file.write_text(content)
    ok(".env configured with DB credentials and server IP.")

def read_db_creds_from_config(config_path="/etc/fusionpbx/config.conf"):
    """Parse DB credentials from FusionPBX config the same way install.sh does."""
    creds = {}
    try:
        text = Path(config_path).read_text()
        for line in text.splitlines():
            for key, field in [("database.0.name", "name"),
                                ("database.0.username", "username"),
                                ("database.0.password", "password")]:
                if line.strip().startswith(key):
                    parts = line.split(None, 2)
                    if len(parts) >= 3:
                        creds[field] = parts[2].strip()
    except FileNotFoundError:
        pass
    return creds

def set_permissions(install_dir: Path):
    ok("Setting file ownership and permissions...")
    run(["chown", "-R", "www-data:www-data", str(install_dir)])
    run(["find", str(install_dir), "-type", "d", "-exec", "chmod", "755", "{}", ";"])
    run(["find", str(install_dir), "-type", "f", "-exec", "chmod", "644", "{}", ";"])
    # Restore execute bits on shell scripts
    run(["find", str(install_dir), "-type", "f", "-name", "*.sh",
         "-exec", "chmod", "755", "{}", ";"])
    storage = install_dir / "storage"
    cache   = install_dir / "bootstrap" / "cache"
    for d in (storage, cache):
        run(["chgrp", "-R", "www-data", str(d)])
        run(["chmod", "-R", "ug+rwx",   str(d)])
    run(["git", "config", "--global", "--add",
         "safe.directory", str(install_dir)])
    ok("Permissions set.")

def copy_index_and_check_auth(install_dir: Path):
    src_index      = install_dir / "install" / "index.php"
    dst_index      = install_dir / "public" / "index.php"
    src_check_auth = install_dir / "install" / "check_auth.php"
    dst_check_auth = install_dir / "public" / "resources" / "check_auth.php"
    (install_dir / "public" / "resources").mkdir(parents=True, exist_ok=True)
    if src_index.exists():
        shutil.copy(src_index, dst_index)
        ok("Main index.php replaced.")
    if src_check_auth.exists():
        shutil.copy(src_check_auth, dst_check_auth)
        ok("check_auth.php copied.")

def copy_assets(install_dir: Path):
    assets_src = install_dir / "install" / "assets"
    assets_dst = install_dir / "storage" / "app" / "public"
    assets_dst.mkdir(parents=True, exist_ok=True)
    if assets_src.exists():
        for f in assets_src.iterdir():
            shutil.copy(f, assets_dst / f.name)
        ok("Assets copied to storage/app/public.")

def setup_supervisor_services(install_dir: Path):
    conf_dir = Path("/etc/supervisor/conf.d")
    conf_dir.mkdir(parents=True, exist_ok=True)
    for conf in ("horizon.conf", "fs-cdr-service.conf",
                 "fs-esl-listener-emergency.conf", "reverb.conf"):
        src = install_dir / "install" / conf
        if src.exists():
            shutil.copy(src, conf_dir / conf)
            ok(f"Copied {conf} to supervisor.")

def setup_systemd_queue_services(install_dir: Path):
    systemd_dir = Path("/etc/systemd/system")
    services = {
        "email_queue": install_dir / "public" / "app" / "email_queue" / "resources" / "service" / "debian.service",
        "fax_queue":   install_dir / "public" / "app" / "fax_queue"   / "resources" / "service" / "debian.service",
        "event_guard": install_dir / "public" / "app" / "event_guard" / "resources" / "service" / "debian.service",
    }
    for svc_name, src in services.items():
        if not src.exists():
            warn(f"Service file not found: {src}  (skipping {svc_name})")
            continue
        dst = systemd_dir / f"{svc_name}.service"
        content = src.read_text()
        content = content.replace(
            "WorkingDirectory=/var/www/fusionpbx",
            f"WorkingDirectory={install_dir}/public"
        )
        content = content.replace(
            f"ExecStart=/usr/bin/php /var/www/fusionpbx/app/{svc_name}/resources/service/{svc_name}.php",
            f"ExecStart=/usr/bin/php {install_dir}/public/app/{svc_name}/resources/service/{svc_name}.php"
        )
        dst.write_text(content)
        ok(f"{svc_name}.service written.")

def service_cmd(action, name, *, ignore_errors=False):
    result = run(["service", name, action], check=not ignore_errors)
    return result

def systemctl_cmd(*args, ignore_errors=False):
    if shutil.which("systemctl"):
        run(["systemctl", *args], check=not ignore_errors)

# ──────────────────────────────────────────────────────────────────────────────
# Main installer
# ──────────────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="FS PBX full installer — Python equivalent of install-fspbx.sh",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Mirrors exactly what this one-liner does:
              wget -O- https://raw.githubusercontent.com/nemerald-voip/fspbx/main/install/install-fspbx.sh | bash

            Must be run as root on Debian 12 (bookworm) or Debian 13 (trixie).
        """)
    )
    parser.add_argument(
        "--install-dir", default="/var/www/fspbx",
        help="Where to install FS PBX (default: /var/www/fspbx)"
    )
    parser.add_argument(
        "--skip-clone", action="store_true",
        help="Skip git clone (repo already present at --install-dir)"
    )
    parser.add_argument(
        "--skip-fusionpbx-download", action="store_true",
        help="Skip FusionPBX public/ download"
    )
    args = parser.parse_args()

    # ── Preflight ────────────────────────────────────────────────────────────
    if os.geteuid() != 0:
        die("Please run as root:  sudo python3 server.py")

    install_dir = Path(args.install_dir)
    codename    = get_os_codename()
    pg_version  = get_pg_version(codename)

    ok(f"Detected OS codename: {codename}")
    ok(f"PostgreSQL version will be: {pg_version}")

    env_extra = {
        "DEBIAN_FRONTEND":    "noninteractive",
        "PHP_VERSION":        "8.4",
        "FREESWITCH_VERSION": "v1.10",
        "POSTGRESQL_VERSION": pg_version,
    }

    # ── 1. Base tools ────────────────────────────────────────────────────────
    ensure_base_tools()

    # ── 2. Fetch FusionPBX version ───────────────────────────────────────────
    fusionpbx_version = fetch_fusionpbx_version()

    # ── 3. Clone FS PBX ──────────────────────────────────────────────────────
    if not args.skip_clone:
        clone_fspbx(install_dir)
    else:
        ok(f"Skipping clone — using existing {install_dir}")

    install_scripts = install_dir / "install"

    # ── 4. Create public/ and download FusionPBX ────────────────────────────
    if not args.skip_fusionpbx_download:
        download_fusionpbx(install_dir, fusionpbx_version)

    # ── 5. System upgrade ────────────────────────────────────────────────────
    ok("Updating and upgrading system packages...")
    run(["apt-get", "update", "-y"], env=env_extra)
    run(["apt-get", "-o", "Dpkg::Options::=--force-confold", "upgrade", "-y"],
        env=env_extra)
    ok("System updated successfully.")

    # ── 6. Preflight tools ───────────────────────────────────────────────────
    run(["apt-get", "update", "-y"], env=env_extra)
    apt_install("libc-bin", "sysvinit-utils")

    # ── 7. Essential dependencies ────────────────────────────────────────────
    ok("Installing essential dependencies...")
    base_pkgs = [
        "wget", "lsb-release", "systemd", "systemd-sysv",
        "ca-certificates", "dialog", "nano", "net-tools", "gpg",
        "ffmpeg", "gnupg", "ghostscript", "libtool-bin",
        "python3-systemd", "libtiff-tools",
        "libreoffice", "libreoffice-base", "libreoffice-common",
        "libreoffice-java-common",
        "supervisor", "redis-server", "apt-transport-https", "npm",
    ]
    apt_install(*base_pkgs)
    if codename == "bookworm":
        apt_install("software-properties-common")
        apt_install("snmpd")
        Path("/etc/snmp/snmpd.conf").write_text("rocommunity public\n")
        service_cmd("restart", "snmpd", ignore_errors=True)
        ok("SNMP installed and configured.")
    ok("Essential dependencies installed.")

    # ── 8. iptables ──────────────────────────────────────────────────────────
    bash(install_scripts / "configure_iptables.sh", env=env_extra, cwd=str(install_dir))

    # ── 9. sngrep ────────────────────────────────────────────────────────────
    bash(install_scripts / "install_sngrep.sh", env=env_extra, cwd=str(install_dir))

    # ── 10. PHP 8.4 ──────────────────────────────────────────────────────────
    bash(install_scripts / "install_php.sh", env=env_extra, cwd=str(install_dir))

    # ── 11. ESL PHP extension ────────────────────────────────────────────────
    run(["sh", str(install_scripts / "install_esl_extension.sh")],
        env=env_extra, cwd=str(install_dir))

    # ── 12. Cron jobs ────────────────────────────────────────────────────────
    run(["sh", str(install_scripts / "install_cron_jobs.sh")],
        env=env_extra, cwd=str(install_dir))

    # ── 13. Sudoers ──────────────────────────────────────────────────────────
    run(["sh", str(install_scripts / "add_web_server_to_sudoers.sh")],
        env=env_extra, cwd=str(install_dir))

    # ── 14. Composer ─────────────────────────────────────────────────────────
    ok("Installing Composer...")
    with tempfile.TemporaryDirectory() as tmp:
        installer = Path(tmp) / "composer-setup.php"
        urllib.request.urlretrieve(
            "https://getcomposer.org/installer", installer)
        run(["php", str(installer)], cwd=tmp)
        composer_phar = Path(tmp) / "composer.phar"
        shutil.move(str(composer_phar), "/usr/local/bin/composer")
    os.chmod("/usr/local/bin/composer", 0o755)
    ok("Composer installed.")

    # ── 15. Node.js 20 ───────────────────────────────────────────────────────
    ok("Installing Node.js 20...")
    run(["apt-get", "update", "-y"], env=env_extra)
    Path("/etc/apt/keyrings").mkdir(parents=True, exist_ok=True)
    if codename == "bookworm":
        gpg_key = subprocess.run(
            ["curl", "-fsSL", "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"],
            capture_output=True).stdout
        gpg_out = subprocess.run(
            ["gpg", "--dearmor", "--batch", "--yes",
             "-o", "/etc/apt/keyrings/nodesource.gpg"],
            input=gpg_key)
        Path("/etc/apt/sources.list.d/nodesource.list").write_text(
            "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] "
            "https://deb.nodesource.com/node_20.x nodistro main\n"
        )
    elif codename == "trixie":
        run(["bash", "-c",
             "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"],
            env=env_extra, shell=False)
    run(["apt-get", "update", "-y"], env=env_extra)
    apt_install("nodejs")
    ok("Node.js installed.")

    # ── 16. Nginx ─────────────────────────────────────────────────────────────
    bash(install_scripts / "install_nginx.sh", env=env_extra, cwd=str(install_dir))

    # Configure Nginx sites
    for old in ("fusionpbx",):
        for base in ("/etc/nginx/sites-enabled", "/etc/nginx/sites-available"):
            p = Path(base) / old
            if p.exists():
                p.unlink()
                ok(f"Removed old site: {p}")

    nginx_conf_dst = Path("/etc/nginx/sites-available/fspbx.conf")
    nginx_conf_src = install_dir / "install" / "nginx_site_config.conf"
    shutil.copy(nginx_conf_src, nginx_conf_dst)
    ok("Copied Nginx site config.")

    symlink = Path("/etc/nginx/sites-enabled/fspbx.conf")
    if symlink.is_symlink(): symlink.unlink()
    symlink.symlink_to(nginx_conf_dst)
    ok("Linked Nginx site config.")

    Path("/etc/nginx/snippets").mkdir(parents=True, exist_ok=True)
    shutil.copy(install_dir / "install" / "nginx_reverb.conf",
                "/etc/nginx/snippets/fspbx-reverb.conf")

    internal_src = install_dir / "install" / "nginx_fspbx_internal.conf"
    internal_dst = Path("/etc/nginx/sites-available/fspbx_internal.conf")
    shutil.copy(internal_src, internal_dst)
    symlink2 = Path("/etc/nginx/sites-enabled/fspbx_internal.conf")
    if symlink2.is_symlink(): symlink2.unlink()
    symlink2.symlink_to(internal_dst)
    ok("Internal Nginx config linked.")

    # Self-signed SSL
    Path("/etc/nginx/ssl/private").mkdir(parents=True, exist_ok=True)
    run(["openssl", "req", "-x509", "-nodes", "-days", "365",
         "-newkey", "rsa:2048",
         "-keyout", "/etc/nginx/ssl/private/privkey.pem",
         "-out",    "/etc/nginx/ssl/fullchain.pem",
         "-subj",   "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=fspbx"])
    ok("Self-signed SSL certificate created.")

    # Reload Nginx
    if shutil.which("systemctl"):
        run(["systemctl", "reload", "nginx"], check=False) or run(["systemctl", "restart", "nginx"])
    else:
        service_cmd("reload", "nginx", ignore_errors=True)
    ok("Nginx reloaded.")

    # FusionPBX cache dir
    Path("/var/cache/fusionpbx").mkdir(parents=True, exist_ok=True)
    run(["chown", "-R", "www-data:www-data", "/var/cache/fusionpbx"])

    # ── 17. FusionPBX apps (git clones) ──────────────────────────────────────
    bash(install_scripts / "install_fusionpbx_apps.sh",
         env=env_extra, cwd=str(install_dir))

    # ── 18. .env + Composer install ──────────────────────────────────────────
    env_file = install_dir / ".env"
    env_example = install_dir / ".env.example"
    if not env_file.exists():
        shutil.copy(env_example, env_file)
        ok(".env created from .env.example")

    run(["composer", "install", "--no-dev", "--prefer-dist",
         "--optimize-autoloader", "--no-progress", "--no-interaction"],
        cwd=str(install_dir))
    ok("Composer dependencies installed.")

    run(["php", "artisan", "key:generate"], cwd=str(install_dir))
    ok("Application key generated.")

    # ── 19. Copy index.php + check_auth.php ──────────────────────────────────
    copy_index_and_check_auth(install_dir)

    # ── 20. FreeSWITCH ───────────────────────────────────────────────────────
    bash(install_scripts / "install_freeswitch.sh",
         env=env_extra, cwd=str(install_dir))
    bash(install_scripts / "install_freeswitch_sounds.sh",
         env=env_extra, cwd=str(install_dir))

    # ── 21. Fail2Ban ─────────────────────────────────────────────────────────
    bash(install_scripts / "install_fail2ban.sh",
         env=env_extra, cwd=str(install_dir))

    # ── 22. FusionPBX config.conf ────────────────────────────────────────────
    etc_fpbx = Path("/etc/fusionpbx")
    etc_fpbx.mkdir(parents=True, exist_ok=True)
    shutil.copy(install_scripts / "fusionpbx_config.conf",
                etc_fpbx / "config.conf")

    # Update document root
    config_conf = etc_fpbx / "config.conf"
    text = config_conf.read_text()
    text = text.replace(
        "document.root = /var/www/fusionpbx",
        f"document.root = {install_dir}/public"
    )
    config_conf.write_text(text)
    ok("FusionPBX config.conf written.")

    # ── 23. PostgreSQL ───────────────────────────────────────────────────────
    bash(install_scripts / "install_postgresql.sh",
         env=env_extra, cwd=str(install_dir))

    # ── 24. Wire DB credentials into .env ────────────────────────────────────
    creds = read_db_creds_from_config(config_conf)
    db_name = creds.get("name",     "fusionpbx")
    db_user = creds.get("username", "fusionpbx")
    db_pass = creds.get("password", "")
    external_ip = get_external_ip()

    setup_env_file(install_dir, db_name, db_user, db_pass, external_ip)

    # ── 25. storage:link + assets ────────────────────────────────────────────
    run(["php", "artisan", "storage:link"], cwd=str(install_dir))
    ok("Storage link created.")
    copy_assets(install_dir)

    # ── 26. File permissions ─────────────────────────────────────────────────
    set_permissions(install_dir)

    # ── 27. Systemd queue services ───────────────────────────────────────────
    setup_systemd_queue_services(install_dir)

    systemctl_cmd("daemon-reload", ignore_errors=True)
    for svc in ("email_queue", "fax_queue", "event_guard"):
        systemctl_cmd("enable", svc, ignore_errors=True)
        service_cmd("stop",  svc, ignore_errors=True)
        service_cmd("start", svc, ignore_errors=True)

    # ── 28. Redis ────────────────────────────────────────────────────────────
    redis_conf_src = install_scripts / "redis.conf"
    if redis_conf_src.exists():
        shutil.copy(redis_conf_src, "/etc/redis/redis.conf")
    service_cmd("restart", "redis-server")
    import time; time.sleep(6)
    ok("Redis restarted.")

    # ── 29. Start FreeSWITCH ─────────────────────────────────────────────────
    ok("Starting FreeSWITCH...")
    systemctl_cmd("enable", "freeswitch", ignore_errors=True)
    systemctl_cmd("start",  "freeswitch", ignore_errors=True)

    # Wait for ESL port 8021
    ok("Waiting for FreeSWITCH ESL port 8021 ...")
    import socket, time
    for _ in range(30):
        try:
            with socket.create_connection(("127.0.0.1", 8021), timeout=2):
                ok("FreeSWITCH ESL port 8021 is ready.")
                break
        except OSError:
            time.sleep(2)
    else:
        warn("FreeSWITCH ESL port 8021 not ready after 60 s — continuing anyway.")

    # ── 30. Supervisor + Horizon ─────────────────────────────────────────────
    setup_supervisor_services(install_dir)

    run(["php", "artisan", "vendor:publish",
         "--provider=Laravel\\Horizon\\HorizonServiceProvider"],
        cwd=str(install_dir))
    ok("Laravel Horizon assets published.")

    run(["supervisorctl", "reread"],  ignore_errors=True); time.sleep(6)
    run(["supervisorctl", "update"],  ignore_errors=True); time.sleep(6)
    systemctl_cmd("restart", "supervisor", ignore_errors=True); time.sleep(6)

    for proc in ("horizon:*", "fs-esl-listener-emergency", "fs-cdr-service"):
        run(["supervisorctl", "restart", proc], check=False); time.sleep(6)

    # ── 31. DB seed ──────────────────────────────────────────────────────────
    ok("Seeding the database and configuring FS PBX...")
    run(["php", "artisan", "fspbx:initial-seed"], cwd=str(install_dir))

    # ── Done ─────────────────────────────────────────────────────────────────
    ok("=" * 60)
    ok(" FS PBX installation completed successfully!")
    ok(f" Open: https://{external_ip}")
    ok("=" * 60)


if __name__ == "__main__":
    main()
