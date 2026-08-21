import json
import unittest
from pathlib import Path


class EmojiDatasetTests(unittest.TestCase):
    def test_nerd_font_dataset_matches_catalogue_and_search_aliases(self):
        path = Path(__file__).parents[1] / "shell/assets/nerd-fonts.json"
        document = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(1, document["schema_version"])
        self.assertEqual("3.4.0", document["nerd_fonts_version"])
        self.assertEqual("Symbols Nerd Font", document["font_family"])
        self.assertEqual(10764, len(document["items"]))
        self.assertEqual(
            {"cod", "custom", "dev", "extra", "fa", "fae", "iec", "indent", "indentation", "linux", "md", "oct", "pl", "ple", "pom", "seti", "weather"},
            {source["key"] for source in document["sources"]},
        )
        filters = {source["key"]: source for source in document["source_filters"]}
        self.assertEqual({"fa", "fae"}, set(filters["fa"]["keys"]))
        self.assertEqual(
            {"iec", "indent", "indentation", "pl", "ple", "pom"},
            set(filters["terminal"]["keys"]),
        )
        self.assertEqual(10, len(filters))
        address_book = next(item for item in document["items"] if item["identifier"] == "nf-fa-address_book")
        for alias in ("nerd font", "nerdfont", "font awesome", "fontawesome", "address book", "fa-address_book"):
            self.assertIn(alias, address_book["keywords"])
        self.assertEqual("Nerd Fonts", address_book["category"])
        self.assertEqual("Symbols Nerd Font", address_book["fontFamily"])
        self.assertEqual(
            {"files", "arrows", "development", "terminal", "communication", "media", "devices", "status", "weather", "interface"},
            {item["subcategory"] for item in document["items"]},
        )

    def test_unicode_dataset_has_all_groups_and_thousands_of_entries(self):
        path = Path(__file__).parents[1] / "shell/assets/emoji.json"
        document = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual("17.0", document["unicode_emoji_version"])
        self.assertEqual("48.2", document["cldr_version"])
        self.assertGreater(len(document["items"]), 3900)
        self.assertEqual(
            {
                "Activities", "Animals & Nature", "Flags", "Food & Drink",
                "Objects", "People & Body", "Smileys & Emotion", "Symbols",
                "Travel & Places",
            },
            {item["category"] for item in document["items"]},
        )
        values = {item["value"] for item in document["items"]}
        self.assertIn("👰‍♀️", values)
        self.assertIn("🫩", values)
        self.assertIn("∑", values)
        self.assertNotIn("✌", values)
        self.assertIn("✌️", values)
        self.assertGreater(len(document["items"]), 6000)
        self.assertLess(len(document["items"]), 7000)
        grinning = next(item for item in document["items"] if item["value"] == "😀")
        self.assertIn("happy", grinning["keywords"])
        blond = [item for item in document["items"] if item["baseValue"] == "👱"]
        self.assertEqual({0, 1, 2, 3, 4, 5}, {item["tone"] for item in blond})

    def test_dataset_uses_picker_category_and_symbol_order(self):
        path = Path(__file__).parents[1] / "shell/assets/emoji.json"
        items = json.loads(path.read_text(encoding="utf-8"))["items"]
        category_order = list(dict.fromkeys(item["category"] for item in items))
        self.assertEqual(
            [
                "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
                "Activities", "Travel & Places", "Objects", "Flags", "Symbols",
            ],
            category_order,
        )

        smileys = [item for item in items if item["category"] == "Smileys & Emotion"]
        subcategories = list(dict.fromkeys(item["subcategory"] for item in smileys))
        self.assertLess(subcategories.index("cat-face"), subcategories.index("face-costume"))
        self.assertLess(subcategories.index("monkey-face"), subcategories.index("heart"))
        self.assertLess(subcategories.index("heart"), subcategories.index("emotion"))

        symbols = [item for item in items if item["category"] == "Symbols"]
        first_text_symbol = next(index for index, item in enumerate(symbols) if item["subcategory"].startswith("text-"))
        self.assertTrue(all(not item["subcategory"].startswith("text-") for item in symbols[:first_text_symbol]))
        self.assertLess(
            next(index for index, item in enumerate(symbols) if item["value"] == "‽"),
            next(index for index, item in enumerate(symbols) if item["subcategory"] == "text-punctuation"),
        )
        self.assertLess(
            next(index for index, item in enumerate(symbols) if item["subcategory"] == "text-punctuation"),
            next(index for index, item in enumerate(symbols) if item["subcategory"] == "text-shape"),
        )
        self.assertLess(
            next(index for index, item in enumerate(symbols) if item["subcategory"] == "text-shape"),
            next(index for index, item in enumerate(symbols) if item["subcategory"] == "text-arrow"),
        )

    def test_picker_uses_twemoji_and_symbol_subheadings(self):
        repository = Path(__file__).parents[1]
        picker = (repository / "shell/modules/EmojiPicker.qml").read_text(encoding="utf-8")
        self.assertIn(': "Twemoji"', picker)
        self.assertNotIn("Noto Color Emoji", picker)
        self.assertFalse((repository / "shell/assets/fontconfig.xml").exists())
        for heading in (
            "Emoji signs", "Common marks & games", "Shapes", "Arrows",
            "Maths & logic", "Currency", "Technical notation",
        ):
            self.assertIn(heading, picker)
        self.assertIn("jumpToSymbolSection", picker)
        self.assertIn("jumpToNerdFontSection", picker)
        self.assertIn('fontFamily ? modelData.item.fontFamily : "Twemoji"', picker)
        self.assertIn('"code"', picker)
        controller = (repository / "shell/modules/EmojiController.qml").read_text(encoding="utf-8")
        self.assertIn("if (tone !== 0)", controller)
        self.assertIn("base.split(root.toneCharacters[index]).join", controller)
        self.assertIn("root.toneKey(item.value)", controller)
        self.assertIn('"Nerd Fonts"', controller)
        self.assertIn('item.name + " " + item.keywords', controller)
        self.assertIn('["#ffdc5d", "#f7dece", "#e0bb95", "#c58c6b", "#a56b46", "#6f432a"]', picker)
        self.assertIn('text: "Choose tones"', picker)
        self.assertIn('text: "Choose skin tones"', picker)
        self.assertIn("controller.activateToneVariant", picker)
        self.assertIn("contextAnchor = item.mapToItem(root.contentItem", picker)
        self.assertIn("onOpened: root.popupOpened()", picker)
        self.assertIn("onClosed: root.popupClosed()", picker)
        self.assertIn("property int activeEmojiPopups: 0", picker)
        self.assertIn("onClicked: toneComposer.defaultSelected = true", picker)
        self.assertIn("model: controller.virtualBrowse ? controller.itemCount : root.gridItems.length", picker)
        self.assertIn('"item": controller.itemAt(index)', picker)
        self.assertNotIn("loadNextPage", picker)
        self.assertIn("property var variantMap", controller)
        self.assertIn("property var multiToneGroups", controller)
        self.assertIn("LauncherState.emojiVariants", controller)
        self.assertIn("property bool virtualBrowse: false", controller)
        self.assertIn("property var browseItems: []", controller)
        self.assertIn("readonly property int itemCount", controller)
        self.assertIn("root.browseItems = pinned.concat(unpinned)", controller)
        self.assertIn("function itemAt(index)", controller)
        self.assertNotIn("browseLimit", controller)
        self.assertNotIn("canLoadMore", controller)

        state = (repository / "shell/modules/LauncherState.qml").read_text(encoding="utf-8")
        self.assertIn("property alias emojiVariants", state)
        self.assertIn("property var emojiVariants", state)

    def test_tone_variants_match_bases_with_presentation_selectors(self):
        path = Path(__file__).parents[1] / "shell/assets/emoji.json"
        items = json.loads(path.read_text(encoding="utf-8"))["items"]
        tone_characters = "🏻🏼🏽🏾🏿"

        def tone_key(value):
            return "".join(character for character in value if character not in tone_characters + "\ufe0e\ufe0f")

        toned_keys = {
            (tone_key(item["value"]), next((index + 1 for index, tone in enumerate(tone_characters) if tone in item["value"]), 0))
            for item in items
        }
        for value in ("🖐️", "✌️", "☝️", "✍️", "⛹️", "🏋️‍♂️"):
            for tone in range(1, 6):
                self.assertIn((tone_key(value), tone), toned_keys)

    def test_dataset_contains_complete_ordered_mixed_tone_groups(self):
        path = Path(__file__).parents[1] / "shell/assets/emoji.json"
        items = json.loads(path.read_text(encoding="utf-8"))["items"]
        tone_characters = "🏻🏼🏽🏾🏿"
        tone_names = (
            "light skin tone", "medium-light skin tone", "medium skin tone",
            "medium-dark skin tone", "dark skin tone",
        )

        def tones(value):
            return tuple(tone_characters.index(character) + 1 for character in value if character in tone_characters)

        def variant_group(name):
            changed = True
            while changed:
                changed = False
                for tone_name in tone_names:
                    for separator in (", ", ": "):
                        suffix = separator + tone_name
                        if name.endswith(suffix):
                            name = name[:-len(suffix)]
                            changed = True
                            break
                    if changed:
                        break
            return {
                "couple with heart: person, person": "couple with heart",
                "kiss: person, person": "kiss",
            }.get(name, name)

        mixed = [item for item in items if len(set(tones(item["value"]))) > 1]
        mixed_groups = {variant_group(item["name"]) for item in mixed}
        groups = {group: set() for group in mixed_groups}
        base_groups = set()
        for item in items:
            pair = tones(item["value"])
            group = variant_group(item["name"])
            if not pair:
                base_groups.add(group)
            elif group not in groups:
                continue
            elif len(pair) == 1:
                groups.setdefault(group, set()).add((pair[0], pair[0]))
            else:
                groups.setdefault(group, set()).add(pair)

        self.assertEqual(380, len(mixed))
        self.assertEqual(19, len(groups))
        expected = {(first, second) for first in range(1, 6) for second in range(1, 6)}
        self.assertTrue(all(pairs == expected for pairs in groups.values()))
        self.assertTrue(set(groups).issubset(base_groups))


if __name__ == "__main__":
    unittest.main()
