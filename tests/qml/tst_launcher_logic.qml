import QtQuick
import QtTest
import "../../shell/shared/Fuzzy.js" as Fuzzy
import "../../shell/shared/LauncherLogic.js" as LauncherLogic

TestCase {
    name: "LauncherLogic"

    function test_desktop_ids_are_normalised() {
        compare(LauncherLogic.normaliseId("Org.Example.App.desktop"), "org.example.app");
    }

    function test_safe_conversion_rewrite() {
        compare(LauncherLogic.qalcQuery("5kg = g"), "5kg to g");
        compare(LauncherLogic.qalcQuery("£20 = $"), "£20 to $");
        compare(LauncherLogic.qalcQuery("x = y"), "x = y");
        compare(LauncherLogic.qalcQuery("5 == 5"), "5 == 5");
        compare(LauncherLogic.qalcQuery("= 5"), "= 5");
    }

    function test_calculation_gate() {
        verify(LauncherLogic.looksLikeCalculation("5 + 5"));
        verify(LauncherLogic.looksLikeCalculation("5kg to g"));
        verify(LauncherLogic.looksLikeCalculation("£20 = $"));
        verify(LauncherLogic.looksLikeCalculation("5kg = g"));
        verify(LauncherLogic.looksLikeCalculation("(-5 + 2) * 3"));
        verify(!LauncherLogic.looksLikeCalculation("Firefox"));
        verify(!LauncherLogic.looksLikeCalculation("x = y"));
        verify(!LauncherLogic.looksLikeCalculation("7zip"));
        verify(!LauncherLogic.looksLikeCalculation("/home/5"));
        verify(!LauncherLogic.looksLikeCalculation("C++17"));
    }

    function test_fuzzy_score() {
        verify(Fuzzy.score("term", "Terminal") > Fuzzy.score("tml", "Terminal"));
        compare(Fuzzy.score("missing", "Terminal"), -1);
    }
}
