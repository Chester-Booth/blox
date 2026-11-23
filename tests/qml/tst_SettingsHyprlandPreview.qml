import QtQuick
import QtTest
import "../../shell/modules" as Modules

TestCase {
    name: "SettingsHyprlandPreview"
    QtObject { id: host; property string scriptRoot: "/isolated"; property string errorMessage: "" }
    Modules.SettingsHyprlandPreview { id: preview; host: host }
    function test_cold_apply_checks_retained_journal_without_an_in_memory_transaction() {
        verify(!preview.transactionActive);
        verify(!preview.restoreFor("close"));
        verify(preview.restoreFor("settings-apply"));
        compare(preview.operation, "restore");
        compare(preview.operationReason, "settings-apply");
    }
}
