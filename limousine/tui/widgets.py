"""SelectableRichLog — a RichLog that joins Textual's mouse text selection.

Ported from bashbuild. RichLog renders pre-styled Strips without baking in
selection offsets, so a plain (non-Shift) drag has nothing to anchor to; we
overlay the selection style per visible line and expose the text via
get_selection."""

from __future__ import annotations

from rich.segment import Segment
from rich.style import Style
from textual.strip import Strip
from textual.widgets import RichLog


class SelectableRichLog(RichLog):
    def render_line(self, y: int) -> Strip:
        scroll_x, scroll_y = self.scroll_offset
        line_index = scroll_y + y
        width = self.scrollable_content_region.width
        if line_index >= len(self.lines):
            return Strip.blank(width, self.rich_style)

        strip = self.lines[line_index]
        selection = self.text_selection
        if selection is not None and (span := selection.get_span(line_index)) is not None:
            start, end = span
            if end == -1:
                end = strip.cell_length
            strip = self._stylize_span(strip, start, end, self._selection_style())

        strip = strip.crop_extend(scroll_x, scroll_x + width, self.rich_style)
        strip = strip.apply_style(self.rich_style)
        return strip.apply_offsets(scroll_x, line_index)

    def _selection_style(self) -> Style:
        styles = self.screen.get_component_styles("screen--selection")
        bg = self.background_colors[1] + styles.background
        style = Style(bgcolor=bg.rich_color)
        if styles.color.a:  # honour an explicit opaque selection foreground
            style += Style(color=styles.color.rich_color)
        return style

    @staticmethod
    def _stylize_span(strip: Strip, start: int, end: int, style: Style) -> Strip:
        n = strip.cell_length
        start = max(0, min(start, n))
        end = max(0, min(end, n))
        if end <= start:
            return strip
        left, middle, right = strip.divide([start, end, n])
        # overlay (post_style) so the highlight wins over any cell background
        # while each segment keeps its own foreground colour
        highlighted = Strip(
            list(Segment.apply_style(middle._segments, None, post_style=style)),
            middle.cell_length,
        )
        return Strip.join([left, highlighted, right])

    def get_selection(self, selection):
        text = "\n".join(strip.text for strip in self.lines)
        return selection.extract(text), "\n"
