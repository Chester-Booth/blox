"""Reserved application context, carried separately from widget configuration."""
from __future__ import annotations

import json

CONTEXT_ENV = 'BLOX_WIDGET_ACTION_CONTEXT'


class ContextUnavailable(ValueError):
    """The launcher cannot place an application in this source workspace."""


def capture_context(value):
    """Copy the exact originating output/workspace. Never consult desktop focus."""
    if not isinstance(value, dict) or set(value) != {'outputName', 'workspace'}:
        raise ValueError('Expected originating output and workspace context')
    output = value['outputName']
    if not isinstance(output, str) or not output or any(ord(c) < 32 for c in output) or len(output.encode('utf-8')) > 256:
        raise ValueError('Invalid originating output')
    workspace = value['workspace']
    if not isinstance(workspace, dict) or set(workspace) != {'id', 'name', 'special'}:
        raise ValueError('Invalid originating workspace')
    identifier, name, special = workspace['id'], workspace['name'], workspace['special']
    if type(identifier) is not int or not isinstance(name, str) or type(special) is not bool:
        raise ValueError('Invalid originating workspace identity')
    if special or not 1 <= identifier <= 2147483647 or name != str(identifier):
        raise ContextUnavailable('Launcher supports positive numeric source workspaces only')
    return {'outputName': output, 'workspace': {'id': identifier, 'name': name, 'special': special}}


def helper_context(value):
    """Translate validated host context into the first-party helper's fixed field."""
    context = capture_context(value)
    return json.dumps({'workspaceId': context['workspace']['id']}, separators=(',', ':'))
