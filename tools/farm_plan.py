#!/usr/bin/env python3
"""Farm plan: the data model shared by the designer app and the game.

The plan is the authored answer to what the terrain shader currently guesses with a
hash. It is deliberately a plain, hand-editable JSON document — the designer app is a
convenience, not the format's owner.

Coordinates. The plan covers a fixed square centred on the world origin, sized so it is
inscribed in the game's flat farm basin: the basin has radius ~380, and a 512x512 square
reaches 362 at its corners, so every cell is guaranteed to be on flat ground. Cells are
2 world units, giving a 256x256 grid — fine enough for a 4-unit road, coarse enough that
the whole grid is 64 KB and repaints instantly.

Cells store a ZONE ID, not a colour or a material. Zones carry the meaning (ground, what
lives there, whether it is fenced), so retyping a zone repaints every cell that belongs
to it. Zone 0 is reserved: "not authored", i.e. leave it to the terrain's own rules.

Rows are run-length encoded as "id:count,id:count". That keeps the file diffable — a
change to one pen touches a handful of lines — without storing 65k integers.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from typing import Any

import numpy as np

VERSION = 1

# Must match scripts/farm_plan.gd.
CELL_SIZE = 2.0
GRID = 256
EXTENT = CELL_SIZE * GRID          # 512 world units
ORIGIN = -EXTENT / 2.0             # -256: the grid's top-left corner in world space

NATURAL_ZONE = 0

# Ground types. The index is the layer in the game's ground Texture2DArray, so the order
# here is load-bearing and must match scripts/terrain_textures.gd.
GROUND_TYPES = ["pasture", "dirt", "road", "crop"]

# Species the game can spawn into a zone. None means the area is just ground.
CONTENTS = ["none", "cow", "horse"]

STRUCTURE_TYPES = ["barn", "shed", "silo", "coop", "trough", "haystack", "well"]

# Editor swatches. Not what the game renders — just what reads clearly top-down.
GROUND_COLOURS = {
    "pasture": (104, 152, 68),
    "dirt": (140, 100, 62),
    "road": (150, 148, 140),
    "crop": (160, 128, 70),
}
# Deliberately desaturated and dark: unpainted ground must not be mistakable for a
# painted pasture zone, or you cannot see what you have actually authored.
NATURAL_COLOUR = (46, 58, 40)


@dataclass
class Zone:
    id: int
    name: str
    ground: str = "pasture"
    contents: str = "none"
    count: int = 0
    fenced: bool = False

    def colour(self) -> tuple[int, int, int]:
        return GROUND_COLOURS.get(self.ground, NATURAL_COLOUR)


@dataclass
class Structure:
    type: str
    x: float
    z: float
    yaw: float = 0.0


@dataclass
class FarmPlan:
    zones: list[Zone] = field(default_factory=list)
    structures: list[Structure] = field(default_factory=list)
    cells: np.ndarray = field(default_factory=lambda: np.zeros((GRID, GRID), np.uint8))

    # ---- zone helpers -------------------------------------------------------

    def zone(self, zone_id: int) -> Zone | None:
        for z in self.zones:
            if z.id == zone_id:
                return z
        return None

    def next_zone_id(self) -> int:
        used = {z.id for z in self.zones}
        for candidate in range(1, 256):
            if candidate not in used:
                return candidate
        raise ValueError("all 255 zone ids are in use")

    # ---- coordinates --------------------------------------------------------

    @staticmethod
    def cell_to_world(col: int, row: int) -> tuple[float, float]:
        """Centre of a cell, in world units."""
        return (ORIGIN + (col + 0.5) * CELL_SIZE, ORIGIN + (row + 0.5) * CELL_SIZE)

    @staticmethod
    def world_to_cell(x: float, z: float) -> tuple[int, int]:
        return (int((x - ORIGIN) / CELL_SIZE), int((z - ORIGIN) / CELL_SIZE))

    # ---- serialisation ------------------------------------------------------

    def to_json(self) -> str:
        doc: dict[str, Any] = {
            "version": VERSION,
            "world": {"cell_size": CELL_SIZE, "grid": GRID, "origin": ORIGIN},
            "zones": [asdict(z) for z in self.zones],
            "structures": [asdict(s) for s in self.structures],
            "cells": [_encode_row(self.cells[r]) for r in range(GRID)],
        }
        return json.dumps(doc, indent=1)

    @classmethod
    def from_json(cls, text: str) -> "FarmPlan":
        doc = json.loads(text)
        if doc.get("version") != VERSION:
            raise ValueError(f"plan version {doc.get('version')!r}, expected {VERSION}")
        w = doc["world"]
        if w["grid"] != GRID or abs(w["cell_size"] - CELL_SIZE) > 1e-6:
            raise ValueError(
                f"plan grid {w['grid']}@{w['cell_size']} does not match this build "
                f"({GRID}@{CELL_SIZE}); the game and the designer must agree"
            )
        plan = cls(
            zones=[Zone(**z) for z in doc["zones"]],
            structures=[Structure(**s) for s in doc["structures"]],
            cells=np.zeros((GRID, GRID), np.uint8),
        )
        for r, row in enumerate(doc["cells"]):
            plan.cells[r] = _decode_row(row)
        return plan

    # ---- derived ------------------------------------------------------------

    def ground_layer_map(self) -> np.ndarray:
        """Cells -> ground layer index, which is what the shader actually samples.

        Zone 0 and any dangling zone id fall back to pasture, so a half-deleted plan
        renders as grass rather than as garbage.
        """
        lut = np.zeros(256, np.uint8)
        for z in self.zones:
            if z.ground in GROUND_TYPES:
                lut[z.id] = GROUND_TYPES.index(z.ground)
        return lut[self.cells]

    def zone_cell_counts(self) -> dict[int, int]:
        ids, counts = np.unique(self.cells, return_counts=True)
        return {int(i): int(c) for i, c in zip(ids, counts)}


def _encode_row(row: np.ndarray) -> str:
    parts: list[str] = []
    value = int(row[0])
    run = 0
    for cell in row:
        cell = int(cell)
        if cell == value:
            run += 1
        else:
            parts.append(f"{value}:{run}")
            value, run = cell, 1
    parts.append(f"{value}:{run}")
    return ",".join(parts)


def _decode_row(text: str) -> np.ndarray:
    out = np.zeros(GRID, np.uint8)
    at = 0
    for part in text.split(","):
        value, _, run = part.partition(":")
        n = int(run)
        out[at:at + n] = int(value)
        at += n
    if at != GRID:
        raise ValueError(f"row decodes to {at} cells, expected {GRID}")
    return out


def default_plan() -> FarmPlan:
    """A small starter farm, so a fresh checkout has something to look at."""
    plan = FarmPlan()
    plan.zones = [
        Zone(1, "Yard", ground="dirt"),
        Zone(2, "Cow Pen", ground="dirt", contents="cow", count=6, fenced=True),
        Zone(3, "Horse Paddock", ground="pasture", contents="horse", count=3, fenced=True),
        Zone(4, "Main Road", ground="road"),
        Zone(5, "Wheat Field", ground="crop"),
    ]

    def rect(zone_id: int, x0: float, z0: float, x1: float, z1: float) -> None:
        c0, r0 = FarmPlan.world_to_cell(x0, z0)
        c1, r1 = FarmPlan.world_to_cell(x1, z1)
        plan.cells[r0:r1, c0:c1] = zone_id

    rect(4, -6, -240, 6, 240)      # road running north-south through the farm
    rect(1, 6, -40, 60, 30)        # yard east of the road
    rect(2, 66, -40, 130, 10)      # cow pen
    rect(3, -120, -60, -12, 40)    # horse paddock west of the road
    rect(5, 6, 40, 120, 150)       # wheat field
    plan.structures = [
        Structure("barn", 30.0, -20.0, 0.0),
        Structure("silo", 52.0, -30.0, 0.0),
        Structure("coop", 20.0, 14.0, 90.0),
        Structure("trough", 80.0, -14.0, 0.0),
        Structure("haystack", 44.0, 18.0, 0.0),
        Structure("well", 14.0, -34.0, 0.0),
        Structure("shed", -30.0, -46.0, 180.0),
    ]
    return plan


if __name__ == "__main__":
    p = default_plan()
    text = p.to_json()
    back = FarmPlan.from_json(text)
    assert (back.cells == p.cells).all(), "round-trip changed the cells"
    print(f"round-trip ok: {len(text)} bytes, {len(p.zones)} zones, "
          f"{len(p.structures)} structures")
    print("cells per zone:", p.zone_cell_counts())
