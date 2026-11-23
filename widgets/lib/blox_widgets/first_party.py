"""Author a new complete Todo/calendar profile. Never load or rewrite user data."""
from pathlib import Path

from .model import default_widget, validate_profile


def todo_calendar_profile(script_root: str) -> dict:
    """Return fresh bindings for a supplied installed shell/scripts directory."""
    root = Path(script_root)
    if not root.is_absolute() or '\0' in script_root:
        raise ValueError('An absolute installed script directory is required')

    def run(topic, operation, timeout):
        return {'kind': 'run', 'command': ['blox-widget-action', topic, operation],
                'workingDirectory': '', 'environment': {}, 'timeoutSeconds': timeout}

    widgets = []
    for topic, producer, left_cap, right_cap in (
        ('todo', 'todo-content.sh', 5, 10), ('calendar', 'gcal-content.sh', 120, 120),
    ):
        widget = default_widget('command', topic, {
            'command': [str(root / 'widgets' / producer)],
            'actions': {'left': run(topic, 'next', left_cap),
                        'right': run(topic, 'edit' if topic == 'todo' else 'open', right_cap)},
        })
        widget['name'] = 'Todo' if topic == 'todo' else 'Calendar'
        widgets.append(widget)
    return validate_profile({'schemaVersion': 1, 'widgets': widgets})
