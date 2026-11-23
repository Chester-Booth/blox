import QtQuick
import QtTest
import Quickshell
import "../../shell/services"
import "../../shell/shared/OutputIdentity.js" as OutputIdentity

TestCase {
    id: root
    name: "MultiMonitorBar"

    Component {
        id: screenComponent
        QtObject {
            property string name: ""
            property int width: 1920
            property int height: 1080
        }
    }

    Component {
        id: controllerComponent
        BarSurfaceController {}
    }

    function test_output_identity_matches_rename_flags_ambiguity_and_keeps_absent() {
        const saved = {
            "edid:absent0000000000": {label: "Home Desk", lastConnector: "DP-4", bar: {position: "top"}}
        };
        const first = OutputIdentity.logicalIdentity({name: "DP-1", make: "Dell", model: "U2723QE", serial: "SN-42"});
        const renamed = OutputIdentity.logicalIdentity({name: "DP-3", make: "Dell", model: "U2723QE", serial: "SN-42"});
        compare(first.identityKind, "edid");
        compare(first.logicalId, renamed.logicalId);

        const resolved = OutputIdentity.resolveOutputs([
            {name: "DP-1", make: "Acme", model: "Twin", serial: "DUP-1"},
            {name: "DP-2", make: "Acme", model: "Twin", serial: "DUP-1"}
        ], saved);
        compare(resolved.connected.length, 2);
        verify(resolved.connected[0].ambiguous);
        verify(resolved.connected[1].ambiguous);
        compare(resolved.connected[0].effectiveId, "connector:DP-1");
        compare(resolved.absent.length, 1);
        compare(resolved.absent[0].logicalId, "edid:absent0000000000");
    }

    function test_hover_and_fullscreen_are_isolated_per_output() {
        const s1 = createTemporaryObject(screenComponent, root, {name: "eDP-1"});
        const s2 = createTemporaryObject(screenComponent, root, {name: "DP-1"});
        Quickshell.screens = [s1, s2];
        const controller = createTemporaryObject(controllerComponent, root);

        controller.syncFullscreenByOutput({
            "eDP-1": {hasFullscreen: false},
            "DP-1": {hasFullscreen: true}
        });
        verify(controller.isBarPinnedOpen("eDP-1"));
        verify(!controller.isBarPinnedOpen("DP-1"));
        verify(!controller.isBarVisible("DP-1"));

        // Hovering DP-1 edge reveals DP-1 only, leaving eDP-1 hover untouched.
        controller.enterEdgeTrigger("DP-1");
        verify(controller.isHoverRevealHeld("DP-1"));
        verify(controller.isBarVisible("DP-1"));
        verify(!controller.isHoverRevealHeld("eDP-1"));

        // Manual bar hide on eDP-1 persists across fullscreen toggle on DP-1.
        controller.setManualBarOpen("eDP-1", false);
        verify(!controller.isBarPinnedOpen("eDP-1"));
        controller.syncFullscreenByOutput({
            "eDP-1": {hasFullscreen: false},
            "DP-1": {hasFullscreen: false}
        });
        verify(controller.isBarPinnedOpen("DP-1"));
        verify(!controller.isBarPinnedOpen("eDP-1"));
    }

    function test_workspace_filtering_defaults_to_this_display_and_respects_overrides() {
        const controller = createTemporaryObject(controllerComponent, root);
        const items = [
            {id: 1, monitor: "eDP-1", active: true, activeOnMonitor: true, empty: false, urgent: false},
            {id: 2, monitor: "eDP-1", active: false, activeOnMonitor: false, empty: true, urgent: false},
            {id: 3, monitor: "DP-1", active: false, activeOnMonitor: true, empty: true, urgent: false},
            {id: 4, monitor: "DP-1", active: false, activeOnMonitor: false, empty: true, urgent: false}
        ];

        // Default is this-display with empty workspaces shown.
        const edpDefault = controller.filterWorkspacesForOutput(items, "eDP-1");
        compare(edpDefault.map(i => i.id), [1, 2]);
        const dpDefault = controller.filterWorkspacesForOutput(items, "DP-1");
        compare(dpDefault.map(i => i.id), [3, 4]);
        verify(dpDefault[0].active);

        // Hiding empty workspaces keeps DP-1's active workspace visible.
        controller.outputOverrides = {
            "connector:DP-1": {bar: {workspaceFilter: "this-display", showEmptyWorkspaces: false}},
            "connector:eDP-1": {bar: {workspaceFilter: "all-displays", showEmptyWorkspaces: true}}
        };
        const dpOccupied = controller.filterWorkspacesForOutput(items, "DP-1");
        compare(dpOccupied.map(i => i.id), [3]);
        const edpAll = controller.filterWorkspacesForOutput(items, "eDP-1");
        compare(edpAll.map(i => i.id), [1, 2, 3, 4]);
    }
}
