import json
import os
import re
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)
PHP = os.environ.get("PHPBOX_PHP", "").split()


def minor(v):
    """Return (major, minor) tuple of a PHP version string."""
    m = re.match(r"(\d+)\.(\d+)", v)
    return (int(m[1]), int(m[2])) if m else (0, 0)


def vkey(v):
    """Sortable key for versions like 8.2.1, v6.7.15.1, 1.7.8.10 or 2.4.8-p3."""
    m = re.match(r"v?(\d+(?:\.\d+)*)(?:-p(\d+))?", v)
    if not m:
        return (0,) * 5
    nums = [int(x) for x in m[1].split(".")][:4]
    return tuple(nums + [0] * (4 - len(nums)) + [int(m[2] or 0)])


def stable(v):
    """True for releases without alpha/beta/rc/dev markers."""
    return not re.search(r"alpha|beta|rc|dev|trunk", v, re.I)


def matches(v, q):
    """True if version v satisfies query q (exact, prefix or latest)."""
    return q == "latest" or v.startswith(q + ".") or v.startswith(q + "-p")


def php_range(lo, hi):
    """Image PHP versions between lo and hi inclusive."""
    return [p for p in PHP if minor(lo) <= minor(p) <= minor(hi)]


def php_constraint(c):
    """Image PHP versions satisfying a composer constraint like ~8.2.0||~8.3.0."""
    out = set()
    for part in re.split(r"\|\|?", c or ""):
        part = part.strip()
        m = re.search(r"(\d+)\.(\d+)", part)
        if not m:
            continue
        lo = (int(m[1]), int(m[2]))
        exact = part.startswith("~") and part.count(".") >= 2 or part[0].isdigit()
        for p in PHP:
            pk = minor(p)
            if exact:
                ok = pk == lo
            elif part.startswith(">="):
                ok = pk >= lo
            else:
                ok = pk >= lo and pk[0] == lo[0]
            if ok:
                out.add(p)
    return sorted(out, key=minor)


def expand(entries):
    """Expand composer/2.0 minified package metadata."""
    out, cur = [], {}
    for e in entries:
        cur = dict(cur)
        for k, v in e.items():
            if v == "__unset":
                cur.pop(k, None)
            else:
                cur[k] = v
        out.append(cur)
    return out


def rows_prestashop(data):
    """Rows (version, php list, base, url) from api.prestashop-project.org."""
    for e in data:
        yield e["version"], php_range(e["php_min_version"], e["php_max_version"]), e["version"], e["zip_download_url"]


def rows_composer(data, package):
    """Rows (version, php list, base, url) from a composer p2 package file."""
    entries = data["packages"][package]
    if data.get("minified"):
        entries = expand(entries)
    for e in entries:
        base = e.get("extra", {}).get("magento_version") or e["version"]
        yield e["version"], php_constraint(e.get("require", {}).get("php")), base, ""


def rows_woocommerce(data):
    """Rows (version, php list, base, url) from the wordpress.org plugin API."""
    php = [p for p in PHP if minor(p) >= minor(data.get("requires_php") or "7.4")]
    for v, url in data["versions"].items():
        yield v, php, v, url


def lock_magento(lock, platform_php):
    """Print version, php and Magento base version detected from a composer.lock."""
    pkgs = {p["name"]: p for p in lock.get("packages", [])}
    for name in ("magento/product-community-edition", "magento/product-enterprise-edition",
                 "mage-os/product-community-edition"):
        if name in pkgs:
            p = pkgs[name]
            base = p.get("extra", {}).get("magento_version") or p["version"]
            break
    else:
        p = pkgs.get("magento/framework")
        if not p:
            sys.exit(1)
        m = re.match(r"103\.0\.(\d+)(-p\d+)?", p["version"])
        if not m:
            sys.exit(1)
        base = f"2.4.{m[1]}{m[2] or ''}"
    php = php_constraint(p.get("require", {}).get("php"))
    if platform_php and minor(platform_php) in [minor(x) for x in PHP]:
        php = [x for x in PHP if minor(x) == minor(platform_php)]
    if not php:
        sys.exit(2)
    print(p["version"].lstrip("v"), php[-1], base.lstrip("v"), "-")


def project_php(composer):
    """Print the newest image PHP allowed by config.platform.php or require.php of a composer.json."""
    platform_php = composer.get("config", {}).get("platform", {}).get("php", "")
    if platform_php:
        php = [x for x in PHP if minor(x) == minor(platform_php)]
    else:
        php = php_constraint(composer.get("require", {}).get("php")) if composer.get("require", {}).get("php") else PHP
    if not php:
        sys.exit(2)
    print(php[-1])


def main():
    source, mode, *rest = sys.argv[1:]
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)
    if source == "lock":
        lock_magento(data, rest[0] if rest else "")
        return
    if source == "project":
        project_php(data)
        return
    if source == "prestashop":
        rows = rows_prestashop(data)
    elif source == "composer":
        rows = rows_composer(data, rest.pop(0))
    else:
        rows = rows_woocommerce(data)
    rows = [r for r in rows if r[1]]
    query = rest[0] if rest else ""

    if mode == "list":
        seen = set()
        for v, php, base, _ in sorted(rows, key=lambda r: vkey(r[0]), reverse=True):
            if stable(v) and v not in seen:
                seen.add(v)
                extra = f"  (Magento {base})" if base != v else ""
                print(f"{v:<14} PHP {php[0]}-{php[-1]}{extra}")
        return

    hits = [r for r in rows if r[0] == query] or [r for r in rows if stable(r[0]) and matches(r[0], query)]
    if not hits:
        sys.exit(1)
    v, php, base, url = max(hits, key=lambda r: vkey(r[0]))
    print(v, php[-1], base, url or "-")


main()
