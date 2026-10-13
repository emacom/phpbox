# WooCommerce

The `woocommerce` platform installs WordPress and the WooCommerce plugin from `api.wordpress.org`.

## Versions

| Component | Source |
|---|---|
| WooCommerce | `api.wordpress.org/plugins/info/1.0/woocommerce.json` |
| WordPress | latest from `api.wordpress.org/core/version-check/1.7/` or `--wp X.Y.Z` |
| PHP | from WooCommerce `requires_php` up to 8.4 (`WC_PHP_MAX`) |
| MariaDB | 11.4 |

| `create` option | Description |
|---|---|
| `--wp X.Y.Z` | WordPress version, defaults to the latest |

## Project from a repository

```bash
phpbox clone woocommerce git@gitlab.example:client/shop.git
phpbox db-import shop ~/dumps/shop.sql.gz
```

The repository contains the WordPress root directory with `wp-content/`. The WordPress core in the repository is optional.

| `clone` step | Source |
|---|---|
| WordPress | `$wp_version` from `wp-includes/version.php`. Without core: latest, downloaded with `wp core download --skip-content` |
| WooCommerce | `Version:` header in `wp-content/plugins/woocommerce/woocommerce.php`, otherwise `git describe` |
| PHP | As in `create`, at most 8.4. Without the WooCommerce plugin: 8.4 |
| Dependencies | `composer install` when `composer.json` exists |

| `db-import` change | Value |
|---|---|
| Table prefix | From the `%options` table name |
| `wp-config.php` | `.orig` copy, then box `DB_*`, `table_prefix`, removed `WP_HOME` and `WP_SITEURL`. No file: `wp config create` |
| `WP_ENVIRONMENT_TYPE` | `local` |
| Addresses | `wp search-replace` of `https://` and `http://` host from the `home` option → box address, without the `guid` column |
| SMTP plugins | Disabled: `wp-mail-smtp`, `post-smtp`, `easy-wp-smtp`, `fluent-smtp`, `smtp-mailer` |
| `wp-content/mu-plugins/phpbox-ca.php` | The WordPress HTTP API trusts `cache/certs/ca-bundle.pem` instead of `wp-includes/certificates` |
| User `ADMIN_USER` | Password `ADMIN_PASSWORD`, role `administrator`. Missing: new user with `ADMIN_EMAIL` |
