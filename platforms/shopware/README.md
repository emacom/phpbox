# Shopware

The `shopware` platform installs Shopware 6 from the `shopware/production` template on Packagist.

## Versions

| Component | Source |
|---|---|
| Shopware | `shopware/core` versions from `repo.packagist.org`, e.g. `6.7`, `6.6.10` or `latest`. Tested on 6.6.10.29 and 6.7.15.1 |
| PHP | highest version allowed by `require.php` of `shopware/core` |
| MariaDB | 11.4 |
| Search | MariaDB. OpenSearch with `--opensearch` |

```bash
phpbox versions shopware
phpbox create shopware 6.7 --name sw67
```

| `create` step | Command |
|---|---|
| Template | `composer create-project --no-install shopware/production:<version>` |
| Docker recipes off | `composer config --json extra.symfony.docker false` |
| Dependencies | `composer install` |
| Box configuration | `.env.local` with the values from "`.env.local`" |
| Shop | `bin/console system:install --basic-setup` with `SHOP_LANG`, `SHOP_CURRENCY` and `ADMIN_EMAIL` |
| Admin account | `admin` gets `ADMIN_PASSWORD` and `ADMIN_EMAIL`. Another `ADMIN_USER` is created with `user:create` |

## Project from a repository

```bash
phpbox clone shopware git@gitlab.example:client/shop.git
phpbox db-import shop ~/dumps/shop.sql.gz
```

| Step | Change |
|---|---|
| `clone` | `VERSION` and PHP from `shopware/core` in `composer.lock`. `composer install --no-scripts`, because the database is empty |
| `db-import` | `.env.local`, `install.lock`, `assets:install`, `theme:compile`, `cache:clear` |
| Sales channel domains | Scheme and host replaced with `https://<name>.localhost`, path kept |
| Mail | `core.mailerSettings.*` removed from `system_config`, so `MAILER_DSN` sends to Mailpit |
| Admin account | `ADMIN_USER` gets `ADMIN_PASSWORD`. A missing account is created |

Two domains differing only in host get the same URL. `UPDATE IGNORE` keeps the second one unchanged.

## `.env.local`

phpbox sets these variables and keeps the other lines of an existing file. A non-empty previous file is copied to `.env.local.<timestamp>.orig`.

```dotenv
APP_ENV=dev
APP_URL=https://<name>.localhost
DATABASE_URL=mysql://shop:shop@db:3306/<db>
MAILER_DSN=smtp://phpbox-mailpit:1025
OPENSEARCH_URL=http://search:9200
SHOPWARE_ES_ENABLED=0               # 1 with the opensearch or elasticsearch service
SHOPWARE_ES_INDEXING_ENABLED=0      # 1 with the opensearch or elasticsearch service
```

## Scheduled tasks and queue

Without `--cron` the queue runs in the administration (admin worker) while it is open in the browser.

| `cron` service command, every 60 s | Task |
|---|---|
| `bin/console scheduled-task:run --no-wait` | Scheduled tasks |
| `bin/console messenger:consume async --time-limit=50` | `async` queue |

## Web server

The document root is `public/`. Only `public/index.php` is executed. `theme`, `media`, `thumbnail`, `bundles`, `sitemap` get a one-year `expires` header.
