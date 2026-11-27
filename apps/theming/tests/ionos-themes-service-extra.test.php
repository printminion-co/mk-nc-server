<?php

/**
 * IONOS(branding): standalone test of the `ncw.themes` registration of ThemesService.
 *
 * Run with: php apps/theming/tests/ionos-themes-service-extra.test.php
 *
 * It loads the REAL ThemesService, ITheme and OCP\Server from this tree. Only what a running server would provide
 * is stubbed: the container behind \OC::$server, the config, the user session, the logger and the built-in theme
 * classes (their dependencies are not needed to test the registry). It needs no composer packages and no PHPUnit,
 * so the series can check the patch anywhere php runs; the real proof is the smoke test on a real install.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

declare(strict_types=1);

namespace {
	$root = dirname(__DIR__, 3);
	require $root . '/apps/theming/lib/ITheme.php';
}

namespace Psr\Log {
	interface LoggerInterface {
		public function warning(string|\Stringable $message, array $context = []): void;
		public function error(string|\Stringable $message, array $context = []): void;
	}
}

namespace OCP {
	interface IConfig {
		public function getSystemValue(string $key, mixed $default = ''): mixed;
		public function getSystemValueString(string $key, string $default = ''): string;
		public function getUserValue(string $userId, string $appName, string $key, string $default = ''): string;
		public function setUserValue(string $userId, string $appName, string $key, string $value): void;
	}
	interface IUser {
		public function getUID(): string;
	}
	interface IUserSession {
		public function getUser(): ?IUser;
	}
}

namespace OCA\Theming\AppInfo {
	class Application {
		public const APP_ID = 'theming';
	}
}

namespace OCA\Theming\Themes {
	abstract class StubTheme implements \OCA\Theming\ITheme {
		public function getId(): string { return static::ID; }
		public function getType(): int { return 1; }
		public function getTitle(): string { return ''; }
		public function getEnableLabel(): string { return ''; }
		public function getDescription(): string { return ''; }
		public function getMeta(): array { return []; }
		public function getMediaQuery(): string { return ''; }
		public function getCSSVariables(): array { return []; }
		public function getCustomCss(): string { return ''; }
	}
	class DefaultTheme extends StubTheme { public const ID = 'default'; }
	class LightTheme extends StubTheme { public const ID = 'light'; }
	class DarkTheme extends StubTheme { public const ID = 'dark'; }
	class HighContrastTheme extends StubTheme { public const ID = 'light-highcontrast'; }
	class DarkHighContrastTheme extends StubTheme { public const ID = 'dark-highcontrast'; }
	class DyslexiaFont extends StubTheme { public const ID = 'opendyslexic'; }
}

namespace Fixture {
	class GoodTheme extends \OCA\Theming\Themes\StubTheme { public const ID = 'good'; }
	class SecondTheme extends \OCA\Theming\Themes\StubTheme { public const ID = 'second'; }
	/** Reuses the id of a built-in theme. */
	class ClashTheme extends \OCA\Theming\Themes\StubTheme { public const ID = 'dark'; }
	class NotATheme {}
	class BrokenTheme extends \OCA\Theming\Themes\StubTheme {
		public const ID = 'broken';
		public function __construct() { throw new \RuntimeException('cannot be built'); }
	}

	class Config implements \OCP\IConfig {
		/** @var array<string, mixed> */
		public array $system = [];
		/** @var string[] */
		public array $systemReads = [];
		public function getSystemValue(string $key, mixed $default = ''): mixed {
			$this->systemReads[] = $key;
			return $this->system[$key] ?? $default;
		}
		public function getSystemValueString(string $key, string $default = ''): string {
			return (string)($this->system[$key] ?? $default);
		}
		public function getUserValue(string $userId, string $appName, string $key, string $default = ''): string { return $default; }
		public function setUserValue(string $userId, string $appName, string $key, string $value): void {}
	}

	class Logger implements \Psr\Log\LoggerInterface {
		/** @var array<int, array{string, array}> */
		public array $warnings = [];
		public array $errors = [];
		public function warning(string|\Stringable $message, array $context = []): void { $this->warnings[] = [(string)$message, $context]; }
		public function error(string|\Stringable $message, array $context = []): void { $this->errors[] = [(string)$message, $context]; }
	}

	class Session implements \OCP\IUserSession {
		public function getUser(): ?\OCP\IUser { return null; }
	}

	/** The part of the server container that \OCP\Server::get uses: it builds the class with no arguments. */
	class Container {
		/** @var string[] */
		public array $resolved = [];
		public function get(string $name): object {
			$this->resolved[] = $name;
			return new $name();
		}
	}
}

namespace {
	class OC {
		public static $server;
	}

	require $root . '/lib/public/Server.php';
	require $root . '/apps/theming/lib/Service/ThemesService.php';

	use Fixture\Config;
	use Fixture\Container;
	use Fixture\Logger;
	use Fixture\Session;
	use OCA\Theming\Service\ThemesService;
	use OCA\Theming\Themes as T;

	const BUILT_IN = ['default', 'light', 'dark', 'light-highcontrast', 'dark-highcontrast', 'opendyslexic'];

	$failures = 0;
	$passed = 0;
	function check(string $name, bool $ok, string $detail = ''): void {
		global $failures, $passed;
		if ($ok) {
			$passed++;
			return;
		}
		$failures++;
		fwrite(STDERR, "FAIL: $name" . ($detail !== '' ? " ($detail)" : '') . "\n");
	}

	/** @return array{ThemesService, Logger, Container, Config} */
	function service(array $system): array {
		$config = new Config();
		$config->system = $system;
		$logger = new Logger();
		$container = new Container();
		OC::$server = $container;
		$service = new ThemesService(
			new Session(), $config, $logger,
			new T\DefaultTheme(), new T\LightTheme(), new T\DarkTheme(),
			new T\HighContrastTheme(), new T\DarkHighContrastTheme(), new T\DyslexiaFont(),
		);
		return [$service, $logger, $container, $config];
	}

	function ids(ThemesService $service): string {
		return implode(',', array_keys($service->getThemes()));
	}

	// no behavior change when the setting is absent, empty or not a list
	foreach (['absent' => [], 'empty list' => ['ncw.themes' => []], 'null' => ['ncw.themes' => null], 'a string' => ['ncw.themes' => 'Fixture\\GoodTheme']] as $label => $system) {
		[$service, $logger, $container] = service($system);
		check("$label: only the built-in themes", ids($service) === implode(',', BUILT_IN), ids($service));
		check("$label: no warning", $logger->warnings === []);
		check("$label: the container resolved nothing", $container->resolved === []);
	}

	// a listed class is registered, resolved through the container, and listed after the built-in ones
	[$service, $logger, $container] = service(['ncw.themes' => ['Fixture\\GoodTheme', 'Fixture\\SecondTheme']]);
	check('registered after the built-in themes', ids($service) === implode(',', [...BUILT_IN, 'good', 'second']), ids($service));
	check('resolved through the container', $container->resolved === ['Fixture\\GoodTheme', 'Fixture\\SecondTheme'], implode(',', $container->resolved));
	check('registered themes are the instances of the container', get_class($service->getThemes()['good']) === 'Fixture\\GoodTheme');
	check('no warning for valid classes', $logger->warnings === []);

	// enforce_theme can pick an extra theme: default and dark stay as fallbacks
	[$service, $logger] = service(['ncw.themes' => ['Fixture\\GoodTheme'], 'enforce_theme' => 'good']);
	check('enforced extra theme', ids($service) === 'default,dark,good', ids($service));
	check('enforced extra theme logs no error', $logger->errors === [] && $logger->warnings === []);
	check('enforced extra theme is the enabled theme of a guest', $service->getEnabledThemes() === ['good']);

	// without the extra theme the old behavior stays: the enforced theme is unknown, so the full list and an error
	[$service, $logger] = service(['enforce_theme' => 'good']);
	$listed = ids($service);
	check('unknown enforced theme falls back to the full list', $listed === implode(',', BUILT_IN), $listed);
	check('unknown enforced theme logs the existing error', count($logger->errors) === 1 && $logger->errors[0][0] === 'Enforced theme not found');

	// enforcing a built-in theme still works
	[$service] = service(['ncw.themes' => ['Fixture\\GoodTheme'], 'enforce_theme' => 'light']);
	check('enforced built-in theme with extra themes configured', ids($service) === 'default,dark,light', ids($service));

	// the legacy `theme` setting (themes/<name>/ folder) does not influence the registration
	[$service, , , $config] = service(['theme' => 'ionos', 'ncw.themes' => ['Fixture\\GoodTheme'], 'enforce_theme' => 'good']);
	check('registration with the legacy theme set', ids($service) === 'default,dark,good', ids($service));
	check('the patch does not read the legacy theme key', !in_array('theme', $config->systemReads, true));

	// bad entries are ignored with one warning each, valid ones around them are still registered
	$bad = [
		'a class that does not exist' => 'Fixture\\DoesNotExist',
		'a class that is not an ITheme' => 'Fixture\\NotATheme',
		'a class that cannot be created' => 'Fixture\\BrokenTheme',
		'a class that reuses a built-in id' => 'Fixture\\ClashTheme',
		'an entry that is not a string' => 42,
		'an interface name' => 'OCA\\Theming\\ITheme',
	];
	foreach ($bad as $label => $entry) {
		[$service, $logger] = service(['ncw.themes' => ['Fixture\\GoodTheme', $entry, 'Fixture\\SecondTheme']]);
		check("$label: the other themes are registered", ids($service) === implode(',', [...BUILT_IN, 'good', 'second']), ids($service));
		check("$label: exactly one warning", count($logger->warnings) === 1, (string)count($logger->warnings));
		check("$label: no error level entry", $logger->errors === []);
		check("$label: the warning names the setting", str_contains($logger->warnings[0][0] ?? '', 'ncw.themes'));
	}
	[, $logger] = service(['ncw.themes' => ['Fixture\\DoesNotExist']]);
	check('the warning names the class', ($logger->warnings[0][1]['class'] ?? '') === 'Fixture\\DoesNotExist');

	// the registry is built once, so reading the themes again does not warn again
	[$service, $logger] = service(['ncw.themes' => ['Fixture\\DoesNotExist']]);
	$service->getThemes();
	$service->getThemes();
	check('one warning however often the themes are read', count($logger->warnings) === 1);

	echo "ionos-themes-service-extra: $passed checks passed, $failures failed\n";
	exit($failures === 0 ? 0 : 1);
}
