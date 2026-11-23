import QtQuick
import QtTest
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "EmojiController"

    property var controller: null

    Component {
        id: controllerComponent

        Modules.EmojiController {
        }
    }

    function init() {
        controller = controllerComponent.createObject(testCase);
        verify(controller);
    }

    function cleanup() {
        if (controller) {
            controller.destroy();
            controller = null;
        }
    }

    function file(name) {
        const result = findChild(controller, name);
        verify(result, "missing FileView " + name);
        return result;
    }

    function emptyNerdFontDocument() {
        const nerdFonts = file("nerd-font-data-file");
        nerdFonts.fixtureText = JSON.stringify({"items": [], "purposes": [], "source_filters": []});
        nerdFonts.loaded();
    }

    function test_malformed_json_is_reported_and_successful_load_recovers() {
        const emoji = file("emoji-data-file");
        emptyNerdFontDocument();

        emoji.fixtureText = "{";
        emoji.loaded();
        compare(controller.emojiLoaded, true);
        compare(controller.emojiCount, 0);
        compare(controller.emptyStateText, "Emoji data could not be loaded.");
        compare(controller.emptyStateIsError, true);

        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();
        compare(controller.emojiDataError, "");
        compare(controller.emojiCount, 0);
        compare(controller.emptyStateText, "No emoji available.");
    }

    function test_valid_json_with_wrong_shape_is_distinct_from_a_valid_empty_dataset() {
        const emoji = file("emoji-data-file");
        emptyNerdFontDocument();

        emoji.fixtureText = JSON.stringify({"items": {"value": "😀"}});
        emoji.loaded();
        compare(controller.emojiCount, 0);
        compare(controller.emptyStateText, "Emoji data could not be loaded.");
        compare(controller.emptyStateIsError, true);

        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();
        compare(controller.emojiDataError, "");
        compare(controller.emptyStateText, "No emoji available.");
        compare(controller.emptyStateIsError, false);
    }

    function test_file_load_failure_is_reported_and_later_success_recovers() {
        const emoji = file("emoji-data-file");
        emptyNerdFontDocument();

        emoji.loadFailed("fixture read failure");
        compare(controller.emojiDataError, "Emoji data could not be loaded.");
        compare(controller.emptyStateText, "Emoji data could not be loaded.");
        compare(controller.emptyStateIsError, true);

        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();
        compare(controller.emojiDataError, "");
        compare(controller.emojiCount, 0);
        compare(controller.emptyStateText, "No emoji available.");
    }

    function test_partial_source_failure_is_visible_with_results_and_clears_after_recovery() {
        const emoji = file("emoji-data-file");
        const nerdFonts = file("nerd-font-data-file");
        emoji.fixtureText = JSON.stringify({"items": [{"value": "😀", "name": "grinning face", "keywords": "smile", "category": "Smileys & Emotion"}]});
        emoji.loaded();
        nerdFonts.loadFailed("fixture read failure");

        compare(controller.itemCount, 1);
        compare(controller.emptyStateText, "");
        compare(controller.partialDataErrorText, "Nerd Font data could not be loaded.");

        nerdFonts.fixtureText = JSON.stringify({"items": [], "purposes": [], "source_filters": []});
        nerdFonts.loaded();
        compare(controller.itemCount, 1);
        compare(controller.emptyStateText, "");
        compare(controller.partialDataErrorText, "");

        nerdFonts.fixtureText = JSON.stringify({"items": [{"value": "nf-test", "name": "test icon", "keywords": "test", "category": "Nerd Fonts", "kind": "nerd-font", "subcategory": "files"}], "purposes": [], "source_filters": []});
        nerdFonts.loaded();
        emoji.loadFailed("fixture read failure");
        compare(controller.itemCount, 1);
        compare(controller.partialDataErrorText, "Emoji data could not be loaded.");

        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();
        compare(controller.itemCount, 1);
        compare(controller.partialDataErrorText, "");
    }

    function test_nf_errors_and_recovery() {
        const emoji = file("emoji-data-file");
        const nerdFonts = file("nerd-font-data-file");
        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();

        controller.category = "Nerd Fonts";
        nerdFonts.fixtureText = JSON.stringify({"items": [], "purposes": {}});
        nerdFonts.loaded();
        compare(controller.nerdFontCount, 0);
        compare(controller.emptyStateText, "Nerd Font data could not be loaded.");
        compare(controller.emptyStateIsError, true);

        nerdFonts.loadFailed("fixture read failure");
        compare(controller.emptyStateText, "Nerd Font data could not be loaded.");
        compare(controller.emptyStateIsError, true);

        nerdFonts.fixtureText = JSON.stringify({"items": [], "purposes": [], "source_filters": []});
        nerdFonts.loaded();
        compare(controller.nerdFontDataError, "");
        compare(controller.emptyStateText, "No Nerd Fonts available.");
        compare(controller.emptyStateIsError, false);
    }

    function test_query_with_no_matches_keeps_the_existing_blank_result_state() {
        emptyNerdFontDocument();
        const emoji = file("emoji-data-file");
        emoji.loadFailed("fixture read failure");
        controller.query = "nothing matches";
        compare(controller.itemCount, 0);
        compare(controller.emptyStateText, "Emoji data could not be loaded.");

        emoji.fixtureText = JSON.stringify({"items": []});
        emoji.loaded();
        compare(controller.emojiDataError, "");
        compare(controller.emptyStateText, "");
    }
}
