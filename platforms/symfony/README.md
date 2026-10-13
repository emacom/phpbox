# Symfony

The `symfony` platform installs `symfony/skeleton` from Packagist with the `webapp` pack.

## Versions

| Component | Source |
|---|---|
| Symfony | `symfony/skeleton` versions from `repo.packagist.org`, e.g. `7.4` or `latest` |
| PHP | highest version allowed by `require.php` of `symfony/skeleton` |
| MariaDB | 11.4 |

```bash
phpbox versions symfony
phpbox create symfony 7.4
```

| `create` step | Command |
|---|---|
| Skeleton | `composer create-project symfony/skeleton:<version>.*` |
| Docker recipes off | `composer config --json extra.symfony.docker false` |
| Full application | `composer require webapp` |
| Box configuration | `.env.local` with the values from "`.env.local`" |
| Connection check | `bin/console dbal:run-sql 'SELECT 1'` |

## Project from a repository

```bash
phpbox clone symfony git@gitlab.example:client/app.git
phpbox db-import app ~/dumps/app.sql.gz
```

| Step | Change |
|---|---|
| `clone` | `composer install`, then `.env.local` |
| `db-import` | `.env.local`, then `var/cache/` cleared |

## `.env.local`

phpbox sets three variables and keeps the other lines of an existing file. The previous file is copied to `.env.local.<timestamp>.orig`.

```dotenv
APP_ENV=dev
DATABASE_URL="mysql://shop:shop@db:3306/<db>?serverVersion=11.4.0-MariaDB&charset=utf8mb4"
MAILER_DSN=smtp://phpbox-mailpit:1025
```

## Web server

The document root is `public/`. Only `public/index.php` is executed. Other `.php` files return 404.
