# Laravel

The `laravel` platform installs `laravel/laravel` from Packagist with MariaDB instead of SQLite.

## Versions

| Component | Source |
|---|---|
| Laravel | `laravel/laravel` versions from `repo.packagist.org`, e.g. `13`, `12.12` or `latest` |
| PHP | highest version allowed by `require.php` of `laravel/laravel` |
| MariaDB | 11.4 |

```bash
phpbox versions laravel
phpbox create laravel 12 --name lv12
```

The default box name contains the full skeleton version, e.g. `lv13110` for `13.11.0`. A shorter name needs `--name`.

| `create` step | Command |
|---|---|
| Skeleton | `composer create-project --no-scripts laravel/laravel:<version>` |
| Package discovery | `composer run-script post-autoload-dump` |
| Box configuration | `.env` with the values from "`.env`", `APP_KEY` when empty |
| Database | `php artisan migrate --force` |
| Public storage | `php artisan storage:link` |

## Project from a repository

```bash
phpbox clone laravel git@gitlab.example:client/app.git
phpbox db-import app ~/dumps/app.sql.gz
```

| Step | Change |
|---|---|
| `clone` | `composer install`, then `.env` from `.env.example` when missing |
| `db-import` | `.env`, then `php artisan optimize:clear` |

Migrations after `clone` without a dump: `phpbox shell app`, then `php artisan migrate`.

## `.env`

phpbox sets these variables and keeps the other lines. A commented line such as `# DB_HOST=127.0.0.1` is replaced. The previous file is copied to `.env.<timestamp>.orig`.

```dotenv
APP_ENV=local
APP_DEBUG=true
APP_URL=https://<name>.localhost
DB_CONNECTION=mariadb
DB_HOST=db
DB_PORT=3306
DB_DATABASE=<db>
DB_USERNAME=shop
DB_PASSWORD=shop
MAIL_MAILER=smtp
MAIL_HOST=phpbox-mailpit
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
```

## Scheduler

The `cron` service runs `php artisan schedule:run` every 60 s.

```bash
phpbox create laravel latest --cron
```

## Web server

The document root is `public/`. Only `public/index.php` is executed. Other `.php` files return 404.
