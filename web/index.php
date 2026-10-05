<?php

declare(strict_types=1);

// Read from the environment so one codebase runs as dev locally and as prod in the
// container (the Dockerfile sets YII_ENV=prod YII_DEBUG=false). Defaults are stock: dev.
defined('YII_DEBUG') or define('YII_DEBUG', filter_var(getenv('YII_DEBUG') ?: 'true', FILTER_VALIDATE_BOOLEAN));
defined('YII_ENV') or define('YII_ENV', getenv('YII_ENV') ?: 'dev');

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../vendor/yiisoft/yii2/Yii.php';

$config = require __DIR__ . '/../config/web.php';

(new yii\web\Application($config))->run();
