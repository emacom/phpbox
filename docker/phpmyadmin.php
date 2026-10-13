<?php
$cfg['Servers'] = [];
$i = 0;
foreach (glob('/boxes/*/.env') ?: [] as $file) {
    preg_match_all('/^(\w+)=(.*)$/m', file_get_contents($file), $m);
    $env = array_combine($m[1], $m[2]);
    $cfg['Servers'][++$i] = [
        'host' => "phpbox-{$env['NAME']}-db-1",
        'verbose' => "{$env['NAME']} ({$env['PLATFORM']} {$env['VERSION']})",
        'auth_type' => 'config',
        'user' => 'root',
        'password' => getenv('PHPBOX_DB_ROOT_PASS'),
    ];
}
$cfg['ServerDefault'] = 1;
