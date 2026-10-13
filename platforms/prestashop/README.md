# PrestaShop

The `prestashop` platform installs PrestaShop 8.x and 9.x from packages at `api.prestashop-project.org`.

## Versions

| PrestaShop | PHP | MariaDB |
|---|---|---|
| 8.x | 8.1 | 10.11 |
| 9.0 | 8.4 | 10.11 |
| 9.1+ | 8.5 | 10.11 |

PHP is the highest version in the range reported by the API.

## Project from a repository

```bash
phpbox clone prestashop git@gitlab.example:client/shop.git --branch develop
phpbox db-import shop ~/dumps/shop.sql.gz
```

| `clone` step | Source |
|---|---|
| Version | `const VERSION` in `src/Core/Version.php`, in 8.0 in `app/AppKernel.php` |
| PHP | Highest version from the API for the detected PrestaShop version. A version missing from the API requires `--php` |
| Admin directory | First directory with `init.php` and `themes/`, stored as `PS_ADMIN_DIR` in `.env` |
| nginx | `boxes/<name>/nginx/admin.conf` with a `location` for an admin directory other than `admin-dev` |
| Dependencies | `composer install` when `composer.json` exists |

| `db-import` change | Value |
|---|---|
| Table prefix | From the `%configuration` table name |
| `shop_url`, `PS_SHOP_DOMAIN`, `PS_SHOP_DOMAIN_SSL` | Box host |
| `PS_SSL_ENABLED`, `PS_SSL_ENABLED_EVERYWHERE` | `1` |
| `PS_MEDIA_SERVERS` | `0` |
| `PS_MAIL_METHOD` | `1`, `mail()` → Mailpit |
| `PS_SHOP_ENABLE` | `1`, shop out of maintenance mode |
| `app/config/parameters.php` | `.orig` copy, then box database credentials and prefix |
| No `parameters.php` in the repository | File from `parameters.yml.dist` with new keys, as in the PrestaShop installer |
| Employee `ADMIN_EMAIL` | Password `ADMIN_PASSWORD`. No account: copy of the first SuperAdmin with this e-mail, assigned to all shops |
