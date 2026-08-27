"""Shared rendering for browsers that accept Chromium theme manifests."""

from __future__ import annotations

from typing import Any

from .core import canonical_json, contrast_ratio, target_colours


# The key fixes the generated extension identity across theme generations.
CHROMIUM_THEME_PUBLIC_KEY = (
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoLDs7yzNkzRrnbnWZSys0JALYg6nvhlYNbRjqEdmte+"
    "RABd5QPN6zZMSTgE+BvkdCqXtdOHzq5iNwrWaAdFfsdAT9D2S7rcUzd8Fzl+3PyMJE4uslqkNzIYxHAnkNvmgJKoIrv"
    "FG/WUMUno04zUevKtO/+LTDGBocw8Mxgpq3UopSWtRcyGodRCoemor94ejCA7c9wxqko4duDidHZP8S2Ll2D1A/Fvqrp"
    "/JhCPNgu5pMMFiuUJAccxoMNY9CFax+HlAcWnsVPQxKkZ9/4JA63jb+oWyDG5rFRcUsppgxTCdu/g98XZD/8JO99Zu2"
    "LYNBwY3OH3CIUlfxlfzPrjtgQIDAQAB"
)


def _mix_colour(first: str, second: str, amount: float) -> str:
    first_channels = [int(first[index:index + 2], 16) for index in (1, 3, 5)]
    second_channels = [int(second[index:index + 2], 16) for index in (1, 3, 5)]
    channels = [round(start + (end - start) * amount) for start, end in zip(first_channels, second_channels)]
    return "#" + "".join(f"{channel:02x}" for channel in channels)


def _rgb(colour: str) -> list[int]:
    return [int(colour[index:index + 2], 16) for index in (1, 3, 5)]


def _distinct_frame(active: str, preferred: str, fallback: str, foreground: str) -> str:
    if preferred != active and contrast_ratio(preferred, foreground) >= 4.5:
        return preferred

    for percentage in range(10, 0, -1):
        candidate = _mix_colour(preferred, fallback, percentage / 100)
        if candidate != active and contrast_ratio(candidate, foreground) >= 4.5:
            return candidate

    # A valid theme can give every surface role the same value. Keep the two
    # browser states distinct in that case, even if the source contrast is
    # already too low for the normal warning to fix.
    for anchor in ("#000000", "#ffffff"):
        for percentage in range(10, 101, 10):
            candidate = _mix_colour(preferred, anchor, percentage / 100)
            if candidate != active and contrast_ratio(candidate, foreground) >= 4.5:
                return candidate
    return "#010101" if active != "#010101" else "#fefefe"


def chromium_frame_colours(theme: dict[str, Any]) -> tuple[str, str]:
    """Return active-tab and inactive-tab colours from Blox roles."""
    colours = target_colours(theme, "helium")
    active = colours["background"]
    inactive = _distinct_frame(active, colours["surface_alt"], colours["surface"], colours["foreground"])
    return active, inactive


def render_chromium_theme(theme: dict[str, Any], name: str = "Blox Chromium theme") -> str:
    """Render one browser-neutral Chromium theme package."""
    colours = target_colours(theme, "helium")
    active_frame, inactive_frame = chromium_frame_colours(theme)
    manifest = {
        "manifest_version": 3,
        "name": name,
        "version": "1.0",
        "key": CHROMIUM_THEME_PUBLIC_KEY,
        "theme": {
            "colors": {
                "frame": _rgb(inactive_frame),
                "frame_inactive": _rgb(inactive_frame),
                "toolbar": _rgb(active_frame),
                "tab_text": _rgb(colours["foreground"]),
                "tab_background_text": _rgb(colours["foreground"]),
                "bookmark_text": _rgb(colours["foreground"]),
                "toolbar_button_icon": _rgb(colours["foreground"]),
                "omnibox_background": _rgb(colours["surface_alt"]),
                "omnibox_text": _rgb(colours["foreground"]),
                "omnibox_results_bg": _rgb(colours["surface"]),
                "omnibox_results_text": _rgb(colours["foreground"]),
                "ntp_background": _rgb(colours["background"]),
                "ntp_text": _rgb(colours["foreground"]),
                "button_background": _rgb(colours["accent"]),
            }
        },
    }
    return canonical_json(manifest)


def render_helium_theme(theme: dict[str, Any]) -> str:
    """Render the Helium adapter's name with the shared Chromium format."""
    return render_chromium_theme(theme, "Blox Helium theme")
