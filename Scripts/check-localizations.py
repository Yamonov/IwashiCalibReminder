#!/usr/bin/env python3
"""Check the app string catalog without building or starting the app."""

import json
import pathlib
import re


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    catalog = json.loads((root / "Sources/ReminderSupport/Resources/Localizable.xcstrings").read_text())
    entries = catalog["strings"]
    assert catalog["sourceLanguage"] == "en"
    used = set()
    literal = r'"(?:\\.|[^"\\])*"'
    for directory in ["App", "Sources/ReminderSupport"]:
        for path in (root / directory).glob("*.swift"):
            source = path.read_text()
            for match in re.finditer(r'(?:L10n\.text\(|String\(localized:\s*)(' + literal + r')', source):
                used.add(json.loads(match[1]))
            for match in re.finditer(literal, source):
                assert not re.search(r"[ぁ-んァ-ヶ一-龯]", match[0]), f"Unlocalized Japanese text: {path}:{match[0]}"
    assert used == set(entries), f"Missing: {used - set(entries)}; unused: {set(entries) - used}"
    for key, entry in entries.items():
        languages = entry["localizations"]
        assert set(languages) == {"en", "ja"}, key
        formats = []
        for language in ["en", "ja"]:
            unit = languages[language]["stringUnit"]
            assert unit["state"] == "translated" and unit["value"], (key, language)
            formats.append(sorted(re.findall(r"%(?:[1-9][0-9]*\$)?(?:llu|ld|@)", unit["value"])))
        assert formats[0] == formats[1], f"Format arguments differ: {key}"
    print(f"Passed: {len(entries)} app strings, complete en/ja translations, matching format arguments")


if __name__ == "__main__":
    main()
