<?php

declare(strict_types=1);

// Read from the environment so one codebase runs as dev locally and as prod in the
// container (the Dockerfile sets YII_ENV=prod YII_DEBUG=false). Defaults are stock: dev.
// getenv($name, true): the PROCESS environment. Under FrankenPHP a plain getenv() sees only
// the request's CGI variables, so the container's YII_ENV=prod was invisible and the app
// booted as dev (loading yii2-debug, which a --no-dev install does not have).
$env = static fn (string $name): string|false => getenv($name, true) ?: getenv($name);
defined('YII_DEBUG') or define('YII_DEBUG', filter_var($env('YII_DEBUG') ?: 'true', FILTER_VALIDATE_BOOLEAN));
defined('YII_ENV') or define('YII_ENV', $env('YII_ENV') ?: 'dev');

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../vendor/yiisoft/yii2/Yii.php';

$config = require __DIR__ . '/../config/web.php';

(new yii\web\Application($config))->run();
