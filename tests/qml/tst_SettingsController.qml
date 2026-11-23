import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "SettingsController"

    Services.SettingsController {
        id: owner
        enableColdRecovery: false
    }

    SignalSpy { id: published; target: owner; signalName: "widgetsPublished" }

    function test_only_successful_widget_publication_requests_reload() {
        published.clear();
        owner.activeOperation = "get";
        owner.finish(resultFixture());
        compare(published.count, 0);
        owner.activeOperation = "apply-widgets";
        const failed = resultFixture();
        failed.ok = false;
        failed.code = "internal";
        owner.finish(failed);
        compare(published.count, 0);
        owner.finish(null);
        compare(published.count, 0);
        owner.finish(resultFixture());
        compare(published.count, 1);
    }

    function resultFixture() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../fixtures/settings-owner-results.json"), false);
        request.send();
        return JSON.parse(request.responseText).success;
    }

    function test_widget_publication_preserves_retained_settings_state() {
        owner.activeOperation = "get";
        const initial = resultFixture();
        owner.finish(initial);
        const savedSettings = JSON.stringify(owner.settings);
        const savedResult = JSON.stringify(owner.typedResult);
        const revision = owner.revision;
        owner.activeOperation = "apply-widgets";
        const publication = resultFixture();
        publication.data.settings = null;
        publication.data.changedComponents = [];
        publication.data.commitState = "not-applicable";
        owner.finish(publication);
        compare(owner.revision, revision);
        compare(JSON.stringify(owner.settings), savedSettings);
        compare(JSON.stringify(owner.typedResult), savedResult);
        compare(owner.commitState, "committed");
    }

    function test_running_owner_guards_one_request_and_returns_typed_result() {
        const started = JSON.parse(owner.begin("set", "{}"));
        compare(started.code, "pending");
        verify(owner.busy);
        const requestId = started.data.requestId;

        const rejected = JSON.parse(owner.begin("reset", "{}"));
        compare(rejected.code, "busy");
        verify(owner.busy);
        compare(JSON.parse(owner.poll(requestId)).code, "pending");

        const success = resultFixture();
        owner.finish(success);
        verify(!owner.busy);
        compare(JSON.parse(owner.poll(requestId)).data.revision, 1);
        compare(owner.revision, 1);
        compare(owner.changedComponents[0], "bar");
        compare(owner.commitState, "committed");
    }
}
