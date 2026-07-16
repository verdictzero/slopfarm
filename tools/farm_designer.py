#!/usr/bin/env python3
"""Farm designer — a top-down grid editor for slopfarm's farm plan.

    python3 tools/farm_designer.py [farm/plan.json]

Paint zones onto the grid, say what each zone is and what lives in it, drop structures,
and save. The game reads the same JSON and rebuilds itself; leave it running and it
picks up saves within a second, so this is a sidecar rather than a build step.

PySide6 rather than tkinter, and the reason is zoom, not the blit. Blitting the 256x256
grid costs tkinter 1.27 ms (PhotoImage reused, fed an in-memory PPM, since PIL.ImageTk is
not installed here) against Qt's 0.04 ms — 32x, but 1.27 ms would have been perfectly
usable and is not a reason to take a dependency. The disqualifier is that tkinter scales
on the CPU: PhotoImage.zoom measures 2.90 / 11.42 / 52.21 ms at 3x / 6x / 12x, so it gets
slower exactly as you zoom in to place a fence, and at the zoom you actually want it is
19 fps. Qt hands the scale to the paint engine's blitter, so pan and zoom stay flat.

Keys
    1-9         select zone            B/R/L/F/I   brush / rect / line / fill / pick
    S           structure tool         [ ]         brush size
    Tab         cycle structure type   E           rotate structure under cursor
    Ctrl+Z/Y    undo / redo            Ctrl+S      save
    Space+drag / middle-drag  pan      wheel       zoom
    Right-drag  erase to natural
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PySide6.QtCore import QPoint, QRect, Qt, QTimer
from PySide6.QtGui import (QAction, QColor, QFont, QImage, QKeySequence, QPainter, QPen,
                           QPixmap)
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDockWidget,
                               QFileDialog, QFormLayout, QHBoxLayout, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
                               QMessageBox, QPushButton, QSpinBox, QVBoxLayout, QWidget)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from farm_plan import (CELL_SIZE, CONTENTS, EXTENT, GRID, GROUND_TYPES, NATURAL_COLOUR,
                       ORIGIN, STRUCTURE_TYPES, FarmPlan, Structure, Zone, default_plan)

BASIN_RADIUS = 380.0   # matches TerrainManager.plains_radius
SPAWN = (24.0, 40.0)   # matches main.gd
UNDO_DEPTH = 60

STRUCTURE_GLYPH = {
    "barn": "B", "shed": "s", "silo": "O", "coop": "c",
    "trough": "t", "haystack": "h", "well": "w",
}


class GridView(QWidget):
    """The map. Owns pan/zoom and all painting interaction."""

    def __init__(self, window: "Designer") -> None:
        super().__init__()
        self.win = window
        self.scale = 3.0
        self.offset = QPoint(20, 20)
        self._panning = False
        self._pan_from = QPoint()
        self._painting = 0        # 0 none, 1 paint, 2 erase
        self._drag_start: tuple[int, int] | None = None
        self._preview: tuple[int, int] | None = None
        self._image: QPixmap | None = None
        self._dirty = True
        self._user_moved = False
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.StrongFocus)

    def invalidate(self) -> None:
        self._dirty = True
        self.update()

    def fit(self) -> None:
        """Frame the whole grid with a margin, so the basin ring is visible too."""
        if self.width() < 50:
            return
        self.scale = max(1.0, min(self.width() / (GRID * 1.35), self.height() / (GRID * 1.12)))
        span = GRID * self.scale
        self.offset = QPoint(int((self.width() - span) / 2), int((self.height() - span) / 2))
        self.update()

    def resizeEvent(self, event) -> None:
        # Only auto-fit until the user takes control of the view.
        if not self._user_moved:
            self.fit()
        super().resizeEvent(event)

    # ---- coordinate plumbing ------------------------------------------------

    def cell_at(self, pos: QPoint) -> tuple[int, int] | None:
        col = int((pos.x() - self.offset.x()) / self.scale)
        row = int((pos.y() - self.offset.y()) / self.scale)
        if 0 <= col < GRID and 0 <= row < GRID:
            return col, row
        return None

    def world_at(self, pos: QPoint) -> tuple[float, float]:
        return (ORIGIN + (pos.x() - self.offset.x()) / self.scale * CELL_SIZE,
                ORIGIN + (pos.y() - self.offset.y()) / self.scale * CELL_SIZE)

    def screen_of_world(self, x: float, z: float) -> QPoint:
        return QPoint(int(self.offset.x() + (x - ORIGIN) / CELL_SIZE * self.scale),
                      int(self.offset.y() + (z - ORIGIN) / CELL_SIZE * self.scale))

    # ---- rendering ----------------------------------------------------------

    def _rebuild(self) -> None:
        plan = self.win.plan
        lut = np.zeros((256, 3), np.uint8)
        lut[:] = NATURAL_COLOUR
        for z in plan.zones:
            lut[z.id] = z.colour()
        rgb = np.ascontiguousarray(lut[plan.cells])
        img = QImage(rgb.data, GRID, GRID, 3 * GRID, QImage.Format_RGB888)
        self._image = QPixmap.fromImage(img.copy())
        self._dirty = False

    def paintEvent(self, _event) -> None:
        if self._dirty or self._image is None:
            self._rebuild()
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(24, 24, 28))
        target = QRect(self.offset, self._image.size() * self.scale)
        # Nearest-neighbour: cells are data, and a smoothed one lies about its edges.
        p.setRenderHint(QPainter.SmoothPixmapTransform, False)
        p.drawPixmap(target, self._image)

        self._draw_world_guides(p)
        if self.scale >= 6:
            self._draw_grid_lines(p)
        self._draw_structures(p)
        self._draw_preview(p)

    def _draw_world_guides(self, p: QPainter) -> None:
        # The flat basin. Anything painted outside it sits on ground that may slope.
        p.setPen(QPen(QColor(90, 130, 200, 150), 1, Qt.DashLine))
        c = self.screen_of_world(0, 0)
        r = int(BASIN_RADIUS / CELL_SIZE * self.scale)
        p.drawEllipse(c, r, r)
        p.setPen(QPen(QColor(90, 130, 200, 90), 1, Qt.DotLine))
        p.drawLine(self.screen_of_world(ORIGIN, 0), self.screen_of_world(-ORIGIN, 0))
        p.drawLine(self.screen_of_world(0, ORIGIN), self.screen_of_world(0, -ORIGIN))

        s = self.screen_of_world(*SPAWN)
        p.setPen(QPen(QColor(255, 240, 120), 2))
        p.drawLine(s.x() - 5, s.y(), s.x() + 5, s.y())
        p.drawLine(s.x(), s.y() - 5, s.x(), s.y() + 5)
        p.setFont(QFont("Sans", 7))
        p.drawText(s.x() + 7, s.y() - 3, "spawn")

    def _draw_grid_lines(self, p: QPainter) -> None:
        p.setPen(QPen(QColor(255, 255, 255, 22), 1))
        step = 5 if self.scale < 12 else 1
        for i in range(0, GRID + 1, step):
            x = int(self.offset.x() + i * self.scale)
            y = int(self.offset.y() + i * self.scale)
            p.drawLine(x, self.offset.y(), x, int(self.offset.y() + GRID * self.scale))
            p.drawLine(self.offset.x(), y, int(self.offset.x() + GRID * self.scale), y)

    def _draw_structures(self, p: QPainter) -> None:
        p.setFont(QFont("Sans", max(7, int(self.scale * 2))))
        for s in self.win.plan.structures:
            at = self.screen_of_world(s.x, s.z)
            size = max(6, int(3.0 / CELL_SIZE * self.scale))
            hot = s is self.win.hovered_structure
            p.setPen(QPen(QColor(255, 255, 255) if hot else QColor(20, 20, 20), 2))
            p.setBrush(QColor(240, 200, 90) if hot else QColor(210, 160, 60))
            p.drawRect(at.x() - size // 2, at.y() - size // 2, size, size)
            # A stub showing which way it faces, so yaw is visible without a readout.
            import math
            rad = math.radians(s.yaw)
            p.setPen(QPen(QColor(30, 30, 30), 2))
            p.drawLine(at.x(), at.y(),
                       int(at.x() + math.sin(rad) * size), int(at.y() - math.cos(rad) * size))
            p.setPen(QPen(QColor(20, 20, 20)))
            p.drawText(at.x() - 3, at.y() + 4, STRUCTURE_GLYPH.get(s.type, "?"))

    def _draw_preview(self, p: QPainter) -> None:
        if self._preview is None:
            return
        col, row = self._preview
        p.setPen(QPen(QColor(255, 255, 255, 160), 1))
        p.setBrush(Qt.NoBrush)
        if self.win.tool in ("rect", "line") and self._drag_start:
            c0, r0 = self._drag_start
            x0, x1 = sorted((c0, col)); y0, y1 = sorted((r0, row))
            p.drawRect(int(self.offset.x() + x0 * self.scale),
                       int(self.offset.y() + y0 * self.scale),
                       int((x1 - x0 + 1) * self.scale), int((y1 - y0 + 1) * self.scale))
        else:
            n = self.win.brush
            p.drawRect(int(self.offset.x() + (col - n // 2) * self.scale),
                       int(self.offset.y() + (row - n // 2) * self.scale),
                       int(n * self.scale), int(n * self.scale))

    # ---- interaction --------------------------------------------------------

    def wheelEvent(self, e) -> None:
        self._user_moved = True
        before = self.world_at(e.position().toPoint())
        factor = 1.25 if e.angleDelta().y() > 0 else 1 / 1.25
        self.scale = max(1.0, min(24.0, self.scale * factor))
        after = self.world_at(e.position().toPoint())
        # Keep the point under the cursor pinned while zooming.
        self.offset += QPoint(int((after[0] - before[0]) / CELL_SIZE * self.scale),
                              int((after[1] - before[1]) / CELL_SIZE * self.scale))
        self.update()

    def mousePressEvent(self, e) -> None:
        if e.button() == Qt.MiddleButton or (
                e.button() == Qt.LeftButton and e.modifiers() & Qt.ShiftModifier):
            self._panning = True
            self._user_moved = True
            self._pan_from = e.position().toPoint()
            return
        cell = self.cell_at(e.position().toPoint())
        if cell is None:
            return
        if self.win.tool == "structure":
            self.win.structure_click(e, self.world_at(e.position().toPoint()))
            return
        self.win.push_undo()
        self._painting = 2 if e.button() == Qt.RightButton else 1
        if self.win.tool in ("rect", "line"):
            self._drag_start = cell
        elif self.win.tool == "fill":
            self.win.flood_fill(cell, 0 if self._painting == 2 else self.win.active_zone)
            self.invalidate()
        elif self.win.tool == "pick":
            self.win.select_zone(int(self.win.plan.cells[cell[1], cell[0]]))
        else:
            self.win.paint(cell, 0 if self._painting == 2 else self.win.active_zone)
            self.invalidate()

    def mouseMoveEvent(self, e) -> None:
        pos = e.position().toPoint()
        if self._panning:
            self.offset += pos - self._pan_from
            self._pan_from = pos
            self.update()
            return
        self._preview = self.cell_at(pos)
        self.win.hover(self.world_at(pos), self._preview)
        if self._painting and self.win.tool in ("brush", "pick") and self._preview:
            if self.win.tool == "brush":
                self.win.paint(self._preview, 0 if self._painting == 2 else self.win.active_zone)
                self.invalidate()
                return
        self.update()

    def mouseReleaseEvent(self, e) -> None:
        if self._panning:
            self._panning = False
            return
        cell = self.cell_at(e.position().toPoint())
        if self._painting and self._drag_start and cell and self.win.tool in ("rect", "line"):
            zone = 0 if self._painting == 2 else self.win.active_zone
            if self.win.tool == "rect":
                self.win.paint_rect(self._drag_start, cell, zone)
            else:
                self.win.paint_line(self._drag_start, cell, zone)
            self.invalidate()
        self._painting = 0
        self._drag_start = None


class Designer(QMainWindow):
    def __init__(self, path: Path) -> None:
        super().__init__()
        self.path = path
        self.plan = FarmPlan.from_json(path.read_text()) if path.exists() else default_plan()
        self.active_zone = self.plan.zones[0].id if self.plan.zones else 0
        self.tool = "brush"
        self.brush = 3
        self.structure_type = STRUCTURE_TYPES[0]
        self.hovered_structure: Structure | None = None
        self._undo: list[np.ndarray] = []
        self._redo: list[np.ndarray] = []
        self._dirty = False

        self.view = GridView(self)
        self.setCentralWidget(self.view)
        self._build_docks()
        self._build_actions()
        self.refresh_zone_list()
        self._retitle()
        self.resize(1180, 820)

    # ---- ui construction ----------------------------------------------------

    def _build_docks(self) -> None:
        dock = QDockWidget("Zones", self)
        dock.setAllowedAreas(Qt.LeftDockWidgetArea)
        panel = QWidget()
        v = QVBoxLayout(panel)

        self.zone_list = QListWidget()
        self.zone_list.currentItemChanged.connect(self._zone_selected)
        v.addWidget(self.zone_list, 1)

        row = QHBoxLayout()
        add = QPushButton("Add")
        add.clicked.connect(self.add_zone)
        rm = QPushButton("Delete")
        rm.clicked.connect(self.delete_zone)
        row.addWidget(add); row.addWidget(rm)
        v.addLayout(row)

        form = QFormLayout()
        self.f_name = QLineEdit(); self.f_name.editingFinished.connect(self._zone_edited)
        self.f_ground = QComboBox(); self.f_ground.addItems(GROUND_TYPES)
        self.f_ground.currentTextChanged.connect(self._zone_edited)
        self.f_contents = QComboBox(); self.f_contents.addItems(CONTENTS)
        self.f_contents.currentTextChanged.connect(self._zone_edited)
        self.f_count = QSpinBox(); self.f_count.setRange(0, 250)
        self.f_count.valueChanged.connect(self._zone_edited)
        self.f_fenced = QCheckBox("Fenced"); self.f_fenced.stateChanged.connect(self._zone_edited)
        form.addRow("Name", self.f_name)
        form.addRow("Ground", self.f_ground)
        form.addRow("Contains", self.f_contents)
        form.addRow("How many", self.f_count)
        form.addRow("", self.f_fenced)
        v.addLayout(form)

        self.zone_stats = QLabel("")
        self.zone_stats.setWordWrap(True)
        v.addWidget(self.zone_stats)

        v.addWidget(QLabel("<b>Structure to place</b>"))
        self.f_structure = QComboBox(); self.f_structure.addItems(STRUCTURE_TYPES)
        self.f_structure.currentTextChanged.connect(lambda t: setattr(self, "structure_type", t))
        v.addWidget(self.f_structure)
        v.addWidget(QLabel("S = structure tool, click to place,\nE rotates, right-click deletes."))

        dock.setWidget(panel)
        self.addDockWidget(Qt.LeftDockWidgetArea, dock)
        self.status = self.statusBar()

    def _build_actions(self) -> None:
        bar = self.addToolBar("Tools")
        for key, name in (("brush", "Brush (B)"), ("rect", "Rect (R)"), ("line", "Line (L)"),
                          ("fill", "Fill (F)"), ("pick", "Pick (I)"), ("structure", "Structure (S)")):
            a = QAction(name, self, checkable=True)
            a.triggered.connect(lambda _c, k=key: self.set_tool(k))
            bar.addAction(a)
            setattr(self, f"_act_{key}", a)
        self._act_brush.setChecked(True)

        def add(seq: str, fn) -> None:
            a = QAction(self); a.setShortcut(QKeySequence(seq)); a.triggered.connect(fn)
            self.addAction(a)

        add("Ctrl+S", self.save)
        add("Ctrl+Z", self.undo)
        add("Ctrl+Y", self.redo)
        add("B", lambda: self.set_tool("brush"))
        add("R", lambda: self.set_tool("rect"))
        add("L", lambda: self.set_tool("line"))
        add("F", lambda: self.set_tool("fill"))
        add("I", lambda: self.set_tool("pick"))
        add("S", lambda: self.set_tool("structure"))
        add("[", lambda: self.set_brush(self.brush - 2))
        add("]", lambda: self.set_brush(self.brush + 2))
        add("Tab", self.cycle_structure)
        add("E", self.rotate_hovered)
        for i in range(1, 10):
            add(str(i), lambda n=i: self.select_zone_index(n - 1))

        fbar = self.addToolBar("File")
        for name, fn in (("Save (Ctrl+S)", self.save), ("Save As", self.save_as),
                         ("Open", self.open), ("Reset to default", self.reset)):
            a = QAction(name, self); a.triggered.connect(fn); fbar.addAction(a)

    # ---- zone plumbing ------------------------------------------------------

    def refresh_zone_list(self) -> None:
        self.zone_list.blockSignals(True)
        self.zone_list.clear()
        counts = self.plan.zone_cell_counts()
        for z in self.plan.zones:
            area = counts.get(z.id, 0) * CELL_SIZE * CELL_SIZE
            item = QListWidgetItem(f"{z.id}  {z.name}   [{z.ground}]  {area:.0f} m²")
            item.setData(Qt.UserRole, z.id)
            r, g, b = z.colour()
            item.setForeground(QColor(r, g, b))
            self.zone_list.addItem(item)
            if z.id == self.active_zone:
                self.zone_list.setCurrentItem(item)
        self.zone_list.blockSignals(False)
        self._sync_form()

    def _sync_form(self) -> None:
        z = self.plan.zone(self.active_zone)
        for w in (self.f_name, self.f_ground, self.f_contents, self.f_count, self.f_fenced):
            w.blockSignals(True)
        if z:
            self.f_name.setText(z.name)
            self.f_ground.setCurrentText(z.ground)
            self.f_contents.setCurrentText(z.contents)
            self.f_count.setValue(z.count)
            self.f_fenced.setChecked(z.fenced)
            cells = self.plan.zone_cell_counts().get(z.id, 0)
            note = ""
            if z.contents != "none" and z.count == 0:
                note = "<br><b style='color:#e88'>contains %s but count is 0 — nothing will spawn</b>" % z.contents
            if z.contents != "none" and cells == 0:
                note += "<br><b style='color:#e88'>no cells painted — nothing will spawn</b>"
            self.zone_stats.setText(f"{cells} cells, {cells * CELL_SIZE * CELL_SIZE:.0f} m²{note}")
        for w in (self.f_name, self.f_ground, self.f_contents, self.f_count, self.f_fenced):
            w.blockSignals(False)

    def _zone_selected(self, item: QListWidgetItem | None) -> None:
        if item:
            self.active_zone = item.data(Qt.UserRole)
            self._sync_form()

    def _zone_edited(self) -> None:
        z = self.plan.zone(self.active_zone)
        if not z:
            return
        z.name = self.f_name.text()
        z.ground = self.f_ground.currentText()
        z.contents = self.f_contents.currentText()
        z.count = self.f_count.value()
        z.fenced = self.f_fenced.isChecked()
        self.mark_dirty()
        self.refresh_zone_list()
        self.view.invalidate()

    def select_zone(self, zone_id: int) -> None:
        if self.plan.zone(zone_id):
            self.active_zone = zone_id
            self.refresh_zone_list()

    def select_zone_index(self, index: int) -> None:
        if 0 <= index < len(self.plan.zones):
            self.select_zone(self.plan.zones[index].id)

    def add_zone(self) -> None:
        try:
            new_id = self.plan.next_zone_id()
        except ValueError as e:
            QMessageBox.warning(self, "Farm designer", str(e))
            return
        self.plan.zones.append(Zone(new_id, f"Zone {new_id}"))
        self.active_zone = new_id
        self.mark_dirty()
        self.refresh_zone_list()

    def delete_zone(self) -> None:
        z = self.plan.zone(self.active_zone)
        if not z:
            return
        self.push_undo()
        self.plan.cells[self.plan.cells == z.id] = 0
        self.plan.zones.remove(z)
        self.active_zone = self.plan.zones[0].id if self.plan.zones else 0
        self.mark_dirty()
        self.refresh_zone_list()
        self.view.invalidate()

    # ---- painting -----------------------------------------------------------

    def paint(self, cell: tuple[int, int], zone: int) -> None:
        col, row = cell
        n = self.brush
        c0, r0 = max(0, col - n // 2), max(0, row - n // 2)
        self.plan.cells[r0:r0 + n, c0:c0 + n] = zone
        self.mark_dirty()

    def paint_rect(self, a: tuple[int, int], b: tuple[int, int], zone: int) -> None:
        x0, x1 = sorted((a[0], b[0])); y0, y1 = sorted((a[1], b[1]))
        self.plan.cells[y0:y1 + 1, x0:x1 + 1] = zone
        self.mark_dirty()

    def paint_line(self, a: tuple[int, int], b: tuple[int, int], zone: int) -> None:
        # Roads want straight runs, so snap to whichever axis dominates.
        x0, y0 = a; x1, y1 = b
        n = self.brush
        if abs(x1 - x0) >= abs(y1 - y0):
            lo, hi = sorted((x0, x1))
            self.plan.cells[max(0, y0 - n // 2):y0 + n // 2 + 1, lo:hi + 1] = zone
        else:
            lo, hi = sorted((y0, y1))
            self.plan.cells[lo:hi + 1, max(0, x0 - n // 2):x0 + n // 2 + 1] = zone
        self.mark_dirty()

    def flood_fill(self, cell: tuple[int, int], zone: int) -> None:
        col, row = cell
        target = int(self.plan.cells[row, col])
        if target == zone:
            return
        cells = self.plan.cells
        stack = [(col, row)]
        while stack:
            c, r = stack.pop()
            if not (0 <= c < GRID and 0 <= r < GRID) or cells[r, c] != target:
                continue
            # Fill the whole horizontal run at once; a per-pixel stack on 65k cells in
            # Python is slow enough to feel broken.
            left = c
            while left > 0 and cells[r, left - 1] == target:
                left -= 1
            right = c
            while right < GRID - 1 and cells[r, right + 1] == target:
                right += 1
            cells[r, left:right + 1] = zone
            for rr in (r - 1, r + 1):
                if 0 <= rr < GRID:
                    for cc in range(left, right + 1):
                        if cells[rr, cc] == target:
                            stack.append((cc, rr))
        self.mark_dirty()

    def set_tool(self, tool: str) -> None:
        self.tool = tool
        for key in ("brush", "rect", "line", "fill", "pick", "structure"):
            getattr(self, f"_act_{key}").setChecked(key == tool)
        self.status.showMessage(f"tool: {tool}", 1500)

    def set_brush(self, n: int) -> None:
        self.brush = max(1, min(41, n))
        self.status.showMessage(f"brush {self.brush} cells ({self.brush * CELL_SIZE:.0f} m)", 1500)
        self.view.update()

    # ---- structures ---------------------------------------------------------

    def structure_click(self, e, world: tuple[float, float]) -> None:
        if e.button() == Qt.RightButton:
            if self.hovered_structure:
                self.plan.structures.remove(self.hovered_structure)
                self.hovered_structure = None
                self.mark_dirty(); self.view.update()
            return
        self.plan.structures.append(Structure(self.structure_type, round(world[0], 1),
                                              round(world[1], 1), 0.0))
        self.mark_dirty()
        self.view.update()

    def cycle_structure(self) -> None:
        i = (STRUCTURE_TYPES.index(self.structure_type) + 1) % len(STRUCTURE_TYPES)
        self.structure_type = STRUCTURE_TYPES[i]
        self.f_structure.setCurrentText(self.structure_type)
        self.status.showMessage(f"structure: {self.structure_type}", 1500)

    def rotate_hovered(self) -> None:
        if self.hovered_structure:
            self.hovered_structure.yaw = (self.hovered_structure.yaw + 45.0) % 360.0
            self.mark_dirty(); self.view.update()

    def hover(self, world: tuple[float, float], cell) -> None:
        near, best = None, 4.0
        for s in self.plan.structures:
            d = ((s.x - world[0]) ** 2 + (s.z - world[1]) ** 2) ** 0.5
            if d < best:
                near, best = s, d
        if near is not self.hovered_structure:
            self.hovered_structure = near
            self.view.update()
        zone_id = int(self.plan.cells[cell[1], cell[0]]) if cell else 0
        z = self.plan.zone(zone_id)
        r = (world[0] ** 2 + world[1] ** 2) ** 0.5
        warn = "   ** outside the flat basin **" if r > BASIN_RADIUS else ""
        self.status.showMessage(
            f"world ({world[0]:7.1f}, {world[1]:7.1f})   {r:5.0f} from origin   "
            f"zone: {z.name if z else 'natural'}{warn}")

    # ---- undo / files -------------------------------------------------------

    def push_undo(self) -> None:
        self._undo.append(self.plan.cells.copy())
        del self._undo[:-UNDO_DEPTH]
        self._redo.clear()

    def undo(self) -> None:
        if self._undo:
            self._redo.append(self.plan.cells.copy())
            self.plan.cells = self._undo.pop()
            self.mark_dirty(); self.refresh_zone_list(); self.view.invalidate()

    def redo(self) -> None:
        if self._redo:
            self._undo.append(self.plan.cells.copy())
            self.plan.cells = self._redo.pop()
            self.mark_dirty(); self.refresh_zone_list(); self.view.invalidate()

    def mark_dirty(self) -> None:
        self._dirty = True
        self._retitle()

    def _retitle(self) -> None:
        self.setWindowTitle(f"slopfarm farm designer — {self.path}{' *' if self._dirty else ''}")

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Write-then-rename: the game may be reading this file on its own clock, and a
        # half-written plan would fail to parse.
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(self.plan.to_json())
        tmp.replace(self.path)
        self._dirty = False
        self._retitle()
        self.status.showMessage(f"saved {self.path}", 2500)

    def save_as(self) -> None:
        name, _ = QFileDialog.getSaveFileName(self, "Save plan", str(self.path), "JSON (*.json)")
        if name:
            self.path = Path(name)
            self.save()

    def open(self) -> None:
        name, _ = QFileDialog.getOpenFileName(self, "Open plan", str(self.path.parent), "JSON (*.json)")
        if not name:
            return
        try:
            self.plan = FarmPlan.from_json(Path(name).read_text())
        except Exception as e:
            QMessageBox.critical(self, "Farm designer", f"Could not load:\n{e}")
            return
        self.path = Path(name)
        self.active_zone = self.plan.zones[0].id if self.plan.zones else 0
        self._dirty = False
        self.refresh_zone_list(); self.view.invalidate(); self._retitle()

    def reset(self) -> None:
        if QMessageBox.question(self, "Farm designer", "Discard this plan and reload the default?") \
                == QMessageBox.Yes:
            self.push_undo()
            self.plan = default_plan()
            self.active_zone = self.plan.zones[0].id
            self.mark_dirty(); self.refresh_zone_list(); self.view.invalidate()


def main() -> int:
    default = Path(__file__).resolve().parent.parent / "farm" / "plan.json"
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    app = QApplication(sys.argv)
    win = Designer(path)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
