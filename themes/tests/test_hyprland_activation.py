"""First-Apply compositor activation against the actual generated Lua file."""
import json
import subprocess
from unittest import TestCase, mock

from themes.lib.blox_theme import hyprland, runtime
from themes.lib.blox_theme.apply_owners import create_apply
from themes.tests.test_apply_owners import ApplyOwnersTests as _Fixture


class HyprlandActivationTests(TestCase):
    setUp = _Fixture.setUp

    def compositor(self, *, ignore_loader=False, override_rounding=False, delayed=False):
        self.reload_sources = []
        self.options = {}
        self.pending_options = None
        self.reads = []
        self.delay_reads = 0
        original_core_runner = self.hyprland_runner

        def reload_options():
            loader = self.root / 'config/hypr/blox-theme.lua'
            self.reload_sources.append(loader.is_file())
            if not loader.is_file() or ignore_loader:
                return
            # Execute the generated Lua with a minimal hl.config collector.
            script = '''local values
hl = { config = function(value) values = value end }
dofile(%s)
local options = {
 ["general:border_size"] = values.general.border_size,
 ["general:gaps_in"] = values.general.gaps_in,
 ["general:gaps_out"] = values.general.gaps_out,
 ["general:col.active_border"] = values.general.col.active_border,
 ["general:col.inactive_border"] = values.general.col.inactive_border,
 ["decoration:rounding"] = values.decoration.rounding,
 ["decoration:inactive_opacity"] = values.decoration.inactive_opacity,
 ["decoration:shadow:color"] = values.decoration.shadow.color,
}
for key, value in pairs(options) do print(key .. "\\t" .. tostring(value)) end
''' % json.dumps(str(loader))
            parsed = subprocess.run(['lua', '-'], input=script, text=True, capture_output=True, check=True)
            options = {}
            for line in parsed.stdout.splitlines():
                key, value = line.split('\t')
                if value.startswith('rgba('):
                    rgba = value[5:-1]
                    data = {'gradient': rgba[-2:] + rgba[:-2] + ' 0deg'}
                elif key.endswith(('gaps_in', 'gaps_out')):
                    data = {'css': ' '.join([value] * 4)}
                elif key.endswith('inactive_opacity'):
                    data = {'float': float(value)}
                else:
                    data = {'int': int(value)}
                options[key] = dict(data, set=True)
            if override_rounding:
                options['decoration:rounding']['int'] = 999
            if delayed:
                self.pending_options = options
                self.delay_reads = 8
            else:
                self.options = options

        def core_runner(command, **kwargs):
            if command == ['hyprctl', 'reload']:
                reload_options()
            return original_core_runner(command, **kwargs)

        def target_runner(command, *, timeout):
            self.assertEqual(timeout, hyprland.COMMAND_TIMEOUT_SECONDS)
            self.commands.append(command)
            if command == ['hyprctl', 'reload']:
                reload_options()
                output = 'ok\n'
            elif command == ['hyprctl', 'configerrors']:
                output = 'no flags were set\n'
            elif command[:2] == ['hyprctl', 'getoption']:
                option = command[2]
                self.reads.append(option)
                if self.pending_options is not None:
                    if not self.delay_reads:
                        self.options = self.pending_options
                        self.pending_options = None
                    else:
                        self.delay_reads -= 1
                output = json.dumps(self.options.get(option, {'set': False}))
            else:
                raise AssertionError(command)
            return subprocess.CompletedProcess(command, 0, output, '')

        for name in ('btop', 'micro'):
            self.settings.set('targets.' + name + '.enabled', False, self.settings.get().revision)
        self.settings.set('targets.hyprland.enabled', True, self.settings.get().revision)
        return create_apply('catppuccin-mocha', run_command=target_runner, hyprland_runner=core_runner)

    def test_first_apply_reloads_new_generated_lua_then_reads_every_global(self):
        coordinator, request = self.compositor()
        result = coordinator.apply(request)
        self.assertEqual(result['code'], 'ok', result)
        self.assertEqual(self.reload_sources, [False, True])
        self.assertEqual(set(self.reads), set(hyprland.expected_options(coordinator.owners['hyprland'].rendered_theme)))
        self.assertIn('Window appearance applied', result['targets']['hyprland']['message'])
        self.assertEqual(result['targets']['hyprland']['state'], 'restart')  # Hyprtoolkit still needs restart.

    def test_acknowledged_reload_without_include_cannot_report_applied(self):
        coordinator, request = self.compositor(ignore_loader=True)
        with mock.patch.object(hyprland.time, 'sleep'):
            result = coordinator.apply(request)
        self.assertEqual(result['code'], 'core-failure')
        self.assertIn('did not load generated appearance', result['error'])
        self.assertIsNone(runtime.current_generation())

    def test_later_global_override_is_reported_without_editing_personal_config(self):
        coordinator, request = self.compositor(override_rounding=True)
        entrypoint = self.root / 'config/hypr/hyprland.lua'
        before = entrypoint.read_bytes()
        with mock.patch.object(hyprland.time, 'sleep'):
            result = coordinator.apply(request)
        self.assertEqual(result['code'], 'core-failure')
        self.assertIn('decoration:rounding', result['error'])
        self.assertEqual(entrypoint.read_bytes(), before)
        self.assertIsNone(runtime.current_generation())

    def test_deferred_reload_waits_for_options_instead_of_trusting_ack(self):
        coordinator, request = self.compositor(delayed=True)
        with mock.patch.object(hyprland.time, 'sleep'):
            result = coordinator.apply(request)
        self.assertEqual(result['code'], 'ok', result)
        self.assertEqual(len(self.reads), 16)

    def test_readback_normalises_signed_colours_gaps_and_rejects_unset(self):
        self.assertEqual(hyprland.option_value('decoration:shadow:color', {'set': True, 'int': -1}), 'ffffffff')
        self.assertEqual(hyprland.option_value('general:gaps_in', {'set': True, 'css': '3 3 3 3'}), (3, 3, 3, 3))
        with self.assertRaises(ValueError):
            hyprland.option_value('decoration:rounding', {'set': False, 'int': 5})

    def test_zero_exit_without_reload_acknowledgement_is_rejected(self):
        runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0, 'reload unsupported', ''))
        with self.assertRaisesRegex(hyprland.HyprlandFailure, 'not acknowledged'):
            hyprland.activate({}, runner)
        self.assertEqual(runner.call_count, 1)

    def test_native_timeout_is_bounded_and_reaches_transaction_rollback(self):
        coordinator, request = self.compositor()
        original_run = runtime.subprocess.run
        timed_calls = []
        def blocked(command, **kwargs):
            if command[:2] == ['hyprctl', 'reload']:
                timed_calls.append(kwargs['timeout'])
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            return original_run(command, **kwargs)
        with mock.patch.object(runtime.subprocess, 'run', side_effect=blocked):
            coordinator.owners['hyprland'].run_command = runtime._run
            # The core fixture still supplies its own compositor responses.
            result = coordinator.apply(request)
        self.assertEqual(result['code'], 'core-failure', result)
        self.assertIn('command timed out: reload', result['error'])
        self.assertIsNone(runtime.current_generation())
        self.assertEqual(timed_calls, [hyprland.COMMAND_TIMEOUT_SECONDS])

    def test_configerrors_and_readback_calls_have_timeout(self):
        for hung in ('configerrors', 'getoption'):
            with self.subTest(hung=hung):
                def command(argv, *, timeout):
                    self.assertEqual(timeout, hyprland.COMMAND_TIMEOUT_SECONDS)
                    if argv[1] == hung:
                        raise subprocess.TimeoutExpired(argv, timeout)
                    return subprocess.CompletedProcess(argv, 0, 'ok' if argv[1] == 'reload' else '', '')
                from themes.lib.blox_theme.core import load_theme
                _, theme = load_theme('catppuccin-mocha')
                with self.assertRaisesRegex(hyprland.HyprlandFailure, 'command timed out: ' + hung):
                    hyprland.activate(theme, command)

    def test_missing_settings_module_is_typed_before_write_failure(self):
        from themes.lib.blox_theme.apply_coordinator import ApplyError
        coordinator, request = self.compositor()
        module = self.root / 'config/blox/hyprland-settings.lua'
        module.unlink()
        before = self.settings.get().data
        with self.assertRaisesRegex(ApplyError, 'Install Blox'):
            coordinator.apply(request)
        self.assertEqual(self.settings.get().data, before)
        self.assertIsNone(runtime.current_generation())
        self.assertFalse((self.root / 'state/blox/theme/apply/apply.json').exists())
        self.assertEqual(self.commands, [])


del _Fixture
